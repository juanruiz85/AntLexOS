//! AntLex OS — corpus de entrenamiento de la IA AntLex (Fase 4).
//! Datos PUROS (sin imports): los usan tools/entrenar_antlex.zig (host) y
//! las pruebas unitarias de src/tests.zig. El kernel NO lo importa (solo
//! embebe los pesos ya entrenados y las preguntas canónicas de nucleo.zig).
//!
//! Temática: SOLO el propio sistema (memoria, disco, ALFS, comandos, reloj,
//! arranque…). Cualquier tema ajeno debe caer por debajo del umbral de
//! confianza y recibir el rechazo educado del kernel.

pub const Ejemplo = struct {
    texto: []const u8,
    intencion: []const u8,
};

pub const EJEMPLOS = [_]Ejemplo{
    // --- saludo -------------------------------------------------------------
    .{ .texto = "hola", .intencion = "saludo" },
    .{ .texto = "hola antlex", .intencion = "saludo" },
    .{ .texto = "buenas", .intencion = "saludo" },
    .{ .texto = "buenos dias", .intencion = "saludo" },
    .{ .texto = "que tal", .intencion = "saludo" },
    .{ .texto = "saludos", .intencion = "saludo" },
    .{ .texto = "hey hola", .intencion = "saludo" },
    // --- despedida ----------------------------------------------------------
    .{ .texto = "adios", .intencion = "despedida" },
    .{ .texto = "hasta luego", .intencion = "despedida" },
    .{ .texto = "chao", .intencion = "despedida" },
    .{ .texto = "nos vemos", .intencion = "despedida" },
    .{ .texto = "me voy", .intencion = "despedida" },
    .{ .texto = "hasta pronto", .intencion = "despedida" },
    // --- identidad ----------------------------------------------------------
    .{ .texto = "quien eres", .intencion = "identidad" },
    .{ .texto = "como te llamas", .intencion = "identidad" },
    .{ .texto = "que eres", .intencion = "identidad" },
    .{ .texto = "eres una ia", .intencion = "identidad" },
    .{ .texto = "cual es tu nombre", .intencion = "identidad" },
    .{ .texto = "quien sos vos", .intencion = "identidad" },
    .{ .texto = "eres antlex", .intencion = "identidad" },
    // --- autor --------------------------------------------------------------
    .{ .texto = "quien te creo", .intencion = "autor" },
    .{ .texto = "quien te hizo", .intencion = "autor" },
    .{ .texto = "quien es tu autor", .intencion = "autor" },
    .{ .texto = "quien programo el sistema", .intencion = "autor" },
    .{ .texto = "de donde vienes", .intencion = "autor" },
    .{ .texto = "quien desarrollo antlex os", .intencion = "autor" },
    // --- version ------------------------------------------------------------
    .{ .texto = "que version eres", .intencion = "version" },
    .{ .texto = "cual es tu version", .intencion = "version" },
    .{ .texto = "que version tienes", .intencion = "version" },
    .{ .texto = "version actual", .intencion = "version" },
    .{ .texto = "que version del sistema", .intencion = "version" },
    .{ .texto = "que version hay", .intencion = "version" },
    .{ .texto = "eres la version mas nueva", .intencion = "version" },
    // --- sistema_info -------------------------------------------------------
    .{ .texto = "que es antlex os", .intencion = "sistema_info" },
    .{ .texto = "que es este sistema", .intencion = "sistema_info" },
    .{ .texto = "hablame del sistema", .intencion = "sistema_info" },
    .{ .texto = "que sistema operativo es", .intencion = "sistema_info" },
    .{ .texto = "describe el sistema", .intencion = "sistema_info" },
    .{ .texto = "que tipo de sistema es esto", .intencion = "sistema_info" },
    .{ .texto = "describe que sistema es", .intencion = "sistema_info" },
    // --- licencia -----------------------------------------------------------
    .{ .texto = "que licencia tienes", .intencion = "licencia" },
    .{ .texto = "eres libre", .intencion = "licencia" },
    .{ .texto = "eres software libre", .intencion = "licencia" },
    .{ .texto = "bajo que licencia", .intencion = "licencia" },
    .{ .texto = "eres de codigo abierto", .intencion = "licencia" },
    .{ .texto = "licencia del sistema", .intencion = "licencia" },
    // --- memoria ------------------------------------------------------------
    .{ .texto = "cuanta memoria tienes", .intencion = "memoria" },
    .{ .texto = "cuanta ram hay", .intencion = "memoria" },
    .{ .texto = "cuanta memoria queda", .intencion = "memoria" },
    .{ .texto = "cuanta ram", .intencion = "memoria" },
    .{ .texto = "memoria total", .intencion = "memoria" },
    .{ .texto = "cuanta memoria disponible", .intencion = "memoria" },
    .{ .texto = "cuanta memoria hay", .intencion = "memoria" },
    // --- cpu ----------------------------------------------------------------
    .{ .texto = "que procesador tienes", .intencion = "cpu" },
    .{ .texto = "que cpu es", .intencion = "cpu" },
    .{ .texto = "como es el procesador", .intencion = "cpu" },
    .{ .texto = "que cpu usas", .intencion = "cpu" },
    .{ .texto = "que micro tienes", .intencion = "cpu" },
    .{ .texto = "cuantos nucleos tienes", .intencion = "cpu" },
    .{ .texto = "que marca de procesador", .intencion = "cpu" },
    // --- pantalla -----------------------------------------------------------
    .{ .texto = "que resolucion tienes", .intencion = "pantalla" },
    .{ .texto = "resolucion de pantalla", .intencion = "pantalla" },
    .{ .texto = "como es la pantalla", .intencion = "pantalla" },
    .{ .texto = "que graficos tienes", .intencion = "pantalla" },
    .{ .texto = "cuantos pixeles", .intencion = "pantalla" },
    .{ .texto = "resolucion del modo grafico", .intencion = "pantalla" },
    .{ .texto = "que modo de video", .intencion = "pantalla" },
    // --- disco --------------------------------------------------------------
    .{ .texto = "que disco tienes", .intencion = "disco" },
    .{ .texto = "como es el disco", .intencion = "disco" },
    .{ .texto = "que disco duro", .intencion = "disco" },
    .{ .texto = "modelo del disco", .intencion = "disco" },
    .{ .texto = "dime del disco", .intencion = "disco" },
    .{ .texto = "que almacenamiento tienes", .intencion = "disco" },
    // --- alfs ---------------------------------------------------------------
    .{ .texto = "que es alfs", .intencion = "alfs" },
    .{ .texto = "hablame del sistema de archivos", .intencion = "alfs" },
    .{ .texto = "como funciona el sistema de archivos", .intencion = "alfs" },
    .{ .texto = "que sistema de archivos usas", .intencion = "alfs" },
    .{ .texto = "alfs que es", .intencion = "alfs" },
    .{ .texto = "explica el sistema de archivos", .intencion = "alfs" },
    .{ .texto = "donde guardas los archivos", .intencion = "alfs" },
    // --- espacio ------------------------------------------------------------
    .{ .texto = "cuanto espacio queda", .intencion = "espacio" },
    .{ .texto = "cuanto espacio libre", .intencion = "espacio" },
    .{ .texto = "espacio en el volumen", .intencion = "espacio" },
    .{ .texto = "queda espacio", .intencion = "espacio" },
    .{ .texto = "cuantos bloques libres", .intencion = "espacio" },
    .{ .texto = "esta lleno el disco", .intencion = "espacio" },
    .{ .texto = "cuanto espacio hay", .intencion = "espacio" },
    // --- fecha --------------------------------------------------------------
    .{ .texto = "que dia es hoy", .intencion = "fecha" },
    .{ .texto = "que fecha es", .intencion = "fecha" },
    .{ .texto = "fecha actual", .intencion = "fecha" },
    .{ .texto = "dime la fecha", .intencion = "fecha" },
    .{ .texto = "en que dia estamos", .intencion = "fecha" },
    .{ .texto = "hoy que dia es", .intencion = "fecha" },
    .{ .texto = "que dia de la semana es", .intencion = "fecha" },
    // --- hora ---------------------------------------------------------------
    .{ .texto = "que hora es", .intencion = "hora" },
    .{ .texto = "dime la hora", .intencion = "hora" },
    .{ .texto = "hora actual", .intencion = "hora" },
    .{ .texto = "que hora tienes", .intencion = "hora" },
    .{ .texto = "que hora hay", .intencion = "hora" },
    .{ .texto = "hora del sistema", .intencion = "hora" },
    // --- uptime -------------------------------------------------------------
    .{ .texto = "cuanto tiempo encendido", .intencion = "uptime" },
    .{ .texto = "cuanto llevas encendido", .intencion = "uptime" },
    .{ .texto = "tiempo de encendido", .intencion = "uptime" },
    .{ .texto = "cuanto llevas funcionando", .intencion = "uptime" },
    .{ .texto = "desde cuando estas encendido", .intencion = "uptime" },
    .{ .texto = "cuanto tiempo llevas", .intencion = "uptime" },
    // --- comandos -----------------------------------------------------------
    .{ .texto = "que comandos hay", .intencion = "comandos" },
    .{ .texto = "que puedo hacer", .intencion = "comandos" },
    .{ .texto = "lista de comandos", .intencion = "comandos" },
    .{ .texto = "que comandos conoces", .intencion = "comandos" },
    .{ .texto = "como pido ayuda", .intencion = "comandos" },
    .{ .texto = "que se puede hacer", .intencion = "comandos" },
    .{ .texto = "muestrame los comandos", .intencion = "comandos" },
    .{ .texto = "como uso el sistema", .intencion = "comandos" },
    // --- teclado ------------------------------------------------------------
    .{ .texto = "como cambio el teclado", .intencion = "teclado" },
    .{ .texto = "teclado en ingles", .intencion = "teclado" },
    .{ .texto = "pon el teclado en ingles", .intencion = "teclado" },
    .{ .texto = "pon teclado espanol", .intencion = "teclado" },
    .{ .texto = "cambiar distribucion", .intencion = "teclado" },
    .{ .texto = "como pongo el teclado us", .intencion = "teclado" },
    .{ .texto = "distribucion de teclado", .intencion = "teclado" },
    // --- arranque -----------------------------------------------------------
    .{ .texto = "como arrancaste", .intencion = "arranque" },
    .{ .texto = "arrancaste por bios", .intencion = "arranque" },
    .{ .texto = "como fue el arranque", .intencion = "arranque" },
    .{ .texto = "bios o uefi", .intencion = "arranque" },
    .{ .texto = "arrancaste con uefi", .intencion = "arranque" },
    .{ .texto = "quien te cargo", .intencion = "arranque" },
    .{ .texto = "como inicio el sistema", .intencion = "arranque" },
    // --- apagar -------------------------------------------------------------
    .{ .texto = "apagate", .intencion = "apagar" },
    .{ .texto = "apaga el sistema", .intencion = "apagar" },
    .{ .texto = "quiero apagar", .intencion = "apagar" },
    .{ .texto = "como apago", .intencion = "apagar" },
    .{ .texto = "apagar ahora", .intencion = "apagar" },
    .{ .texto = "puedes apagarte", .intencion = "apagar" },
    // --- reiniciar ----------------------------------------------------------
    .{ .texto = "reiniciate", .intencion = "reiniciar" },
    .{ .texto = "reinicia el sistema", .intencion = "reiniciar" },
    .{ .texto = "quiero reiniciar", .intencion = "reiniciar" },
    .{ .texto = "como reinicio", .intencion = "reiniciar" },
    .{ .texto = "reiniciar ahora", .intencion = "reiniciar" },
    .{ .texto = "puedes reiniciarte", .intencion = "reiniciar" },
    .{ .texto = "quiero hacer reboot", .intencion = "reiniciar" },
    // --- archivos -----------------------------------------------------------
    .{ .texto = "como veo los archivos", .intencion = "archivos" },
    .{ .texto = "como listo archivos", .intencion = "archivos" },
    .{ .texto = "donde estan mis archivos", .intencion = "archivos" },
    .{ .texto = "como abro un archivo", .intencion = "archivos" },
    .{ .texto = "como creo un archivo", .intencion = "archivos" },
    .{ .texto = "como guardo un archivo", .intencion = "archivos" },
    .{ .texto = "como borro un archivo", .intencion = "archivos" },
    // --- sincronizar --------------------------------------------------------
    .{ .texto = "los archivos sobreviven", .intencion = "sincronizar" },
    .{ .texto = "se guardan los cambios", .intencion = "sincronizar" },
    .{ .texto = "persisten los datos", .intencion = "sincronizar" },
    .{ .texto = "sobrevive un reinicio", .intencion = "sincronizar" },
    .{ .texto = "como guardo los cambios", .intencion = "sincronizar" },
    .{ .texto = "que es sincronizar", .intencion = "sincronizar" },
    .{ .texto = "cuando se guarda en disco", .intencion = "sincronizar" },
    // --- gracias ------------------------------------------------------------
    .{ .texto = "gracias", .intencion = "gracias" },
    .{ .texto = "muchas gracias", .intencion = "gracias" },
    .{ .texto = "te lo agradezco", .intencion = "gracias" },
    .{ .texto = "gracias antlex", .intencion = "gracias" },
    .{ .texto = "perfecto gracias", .intencion = "gracias" },
    .{ .texto = "genial gracias", .intencion = "gracias" },
};

/// Preguntas ajenas al sistema: el clasificador debe dejarlas por debajo
/// del umbral (diagnóstico del entrenador y de las pruebas host).
pub const ADVERSARIALES = [_][]const u8{
    "cual es la capital de francia",
    "quien gano el partido de futbol",
    "como hacer una tarta de queso",
    "que tiempo va a hacer manana",
    "recomiendame una pelicula",
    "cuanto vale el bitcoin",
    "traduce hello al japones",
    "cuentame un chiste",
};
