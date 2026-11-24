from tools.common import DatasetError, read_json, write_json
from tools.make_splits import assign_groups, main, make_splits
from tests.helpers import TempDirTestCase

RATIOS = {"train": 0.7, "validation": 0.15, "test": 0.15}


def fake_meta(folder, plan, project, n_tiles, counts=None):
    folder.mkdir(parents=True, exist_ok=True)
    for i in range(n_tiles):
        tid = f"{plan}_x{i:06d}_y000000"
        write_json(folder / f"{tid}.json", {
            "tile_id": tid, "source_plan_id": plan, "project_id": project,
            "source_image_sha256": f"sha_{plan}", "class_pixel_counts": counts or [100, 5, 1, 1, 1, 1]})


class TestAssignGroups(TempDirTestCase):
    def test_groups_are_indivisible_and_cover_all(self):
        sizes = {f"g{i}": (i % 5 + 1) * 3 for i in range(20)}
        out = assign_groups(sizes, RATIOS, seed=1)
        flat = [g for s in out.values() for g in s]
        self.assertEqual(sorted(flat), sorted(sizes))
        self.assertEqual(len(flat), len(set(flat)))
        total = sum(sizes.values())
        train = sum(sizes[g] for g in out["train"]) / total
        self.assertAlmostEqual(train, 0.70, delta=0.05)

    def test_every_split_non_empty_with_three_groups(self):
        out = assign_groups({"a": 50, "b": 40, "c": 30}, RATIOS, seed=0)
        self.assertTrue(all(out[s] for s in out))

    def test_deterministic(self):
        sizes = {f"g{i}": 10 for i in range(12)}
        self.assertEqual(assign_groups(sizes, RATIOS, 42), assign_groups(sizes, RATIOS, 42))


class TestMakeSplits(TempDirTestCase):
    def test_projects_never_shared_between_splits(self):
        meta = self.root / "metadata"
        for p in range(10):
            fake_meta(meta, f"plan_{p}a", f"proj_{p}", 5 + p)
            fake_meta(meta, f"plan_{p}b", f"proj_{p}", 3)          # 2 planos por proyecto
        m = make_splits(meta, self.root / "splits", seed=7)
        owners = {}
        for split in ("train", "validation", "test"):
            for tid in (self.root / "splits" / f"{split}.txt").read_text(encoding="utf-8").split():
                proj = read_json(meta / f"{tid}.json")["project_id"]
                owners.setdefault(proj, set()).add(split)
        self.assertTrue(all(len(v) == 1 for v in owners.values()))
        self.assertEqual(sum(m["tiles_assigned"].values()), sum(5 + p + 3 for p in range(10)))

    def test_by_source_plan_warns_about_shared_projects(self):
        meta = self.root / "metadata"
        fake_meta(meta, "plan_a", "proj_1", 4)
        fake_meta(meta, "plan_b", "proj_1", 4)
        fake_meta(meta, "plan_c", "proj_2", 4)
        m = make_splits(meta, self.root / "splits", group_by="source_plan_id")
        self.assertTrue(any("source_plan_id" in w for w in m["warnings"]))

    def test_inconsistent_metadata_blocks_split(self):
        meta = self.root / "metadata"
        fake_meta(meta, "plan_a", "proj_1", 2)
        fake_meta(meta, "plan_b", "proj_2", 2)
        rec = read_json(meta / "plan_b_x000000_y000000.json")
        rec["source_image_sha256"] = "sha_plan_a"   # misma imagen con otro ID → fuga
        write_json(meta / "plan_b_x000000_y000000.json", rec)
        with self.assertRaises(DatasetError):
            make_splits(meta, self.root / "splits")

    def test_warns_when_class_missing_from_eval_split(self):
        meta = self.root / "metadata"
        fake_meta(meta, "plan_a", "proj_1", 20, counts=[100, 5, 1, 1, 1, 9])
        fake_meta(meta, "plan_b", "proj_2", 4, counts=[100, 5, 1, 1, 1, 0])
        fake_meta(meta, "plan_c", "proj_3", 4, counts=[100, 5, 1, 1, 1, 0])
        m = make_splits(meta, self.root / "splits")
        self.assertTrue(any("[5]" in w for w in m["warnings"]), m["warnings"])

    def test_too_few_groups_and_bad_ratios(self):
        meta = self.root / "metadata"
        fake_meta(meta, "plan_a", "proj_1", 3)
        m = make_splits(meta, self.root / "splits")
        self.assertTrue(any("grupos" in w for w in m["warnings"]))
        self.assertEqual(main(["--metadata", str(meta), "--output", str(self.root / "s"),
                               "--train", "0.8", "--validation", "0.3", "--test", "0.1"]), 1)
