/// Licencias de recursos que no vienen de paquetes Dart: fuentes del informe y datos
/// de entrenamiento. Aparecen en Configuración → Licencias.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const swissDwellingsAttribution =
    'Standfest, M., Franzen, M., Schröder, Y., Gonzalez Medina, L., Villanueva Hernandez, Y., Buck, J. H., '
    'Tan, Y.-L., Niedzwiecka, M., Colmegna, R. (2022). Swiss Dwellings (v3.0.0). Zenodo. '
    'https://doi.org/10.5281/zenodo.7788422. Licencia CC BY 4.0 '
    '(https://creativecommons.org/licenses/by/4.0/). STRUCTURA dibujó estas geometrías con estilos '
    'aleatorios para entrenar y evaluar sus modelos de visión; no se distribuyen los datos originales.';

void registerExtraLicenses() {
  LicenseRegistry.addLicense(() async* {
    final roboto = await rootBundle.loadString('assets/fonts/roboto_license.txt');
    yield LicenseEntryWithLineBreaks(['Roboto (fuente del informe PDF)'], roboto);
    yield const LicenseEntryWithLineBreaks(['Swiss Dwellings (datos de entrenamiento)'], swissDwellingsAttribution);
  });
}
