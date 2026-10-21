# BitlockerMac

**Abre en el Mac discos externos cifrados con BitLocker desde un icono de la barra de menús.**

[English](README.md)

BitlockerMac es una pequeña app para la barra de menús de macOS (un solo fichero Swift) que detecta los discos externos cifrados con BitLocker en Windows, te pide la clave en una ventanita y los abre en Finder. Por debajo usa [dislocker](https://github.com/Aorimn/dislocker), [macFUSE](https://macfuse.github.io/) y, para escribir, [ntfs-3g](https://github.com/tuxera/ntfs-3g).

**No hace falta bajar la seguridad del Mac.** macFUSE se usa en su modo FSKit, que funciona sin extensión del kernel: no hay que arrancar en modo Recuperación ni reducir la seguridad.

## Características

- **Icono en la barra de menús** (un disco con un candado, cerrado o abierto) con los discos BitLocker conectados y los que tienes abiertos.
- **Ventana para la clave**: acepta la contraseña de BitLocker o la clave de recuperación de 48 dígitos.
- **Solo lectura por defecto**, con el soporte NTFS/exFAT de macOS.
- **Escritura opcional (experimental)** con una casilla: NTFS con ntfs-3g; exFAT/FAT con el soporte de macOS.
- **Expulsar** desde el mismo menú: cierra el volumen y expulsa el disco físico para poder desenchufarlo.
- Detecta solo los discos que se conectan y desconectan.
- Interfaz en español o en inglés.

## Requisitos

- macOS 15.4 o posterior (el modo FSKit de macFUSE lo necesita). Desarrollado y probado en macOS 26 (Tahoe) en Apple Silicon; en Macs Intel debería funcionar, pero no está probado.
- [Homebrew](https://brew.sh).
- Las Command Line Tools de Apple, para compilar: `xcode-select --install`.
- Para escribir: macFUSE 5.5 o posterior (la 5.4 tiene un fallo de corrupción de datos en FSKit). Con la 5.4 los discos se abren en solo lectura.

## Instalación

```bash
curl -fsSL https://raw.githubusercontent.com/rubo88/BitlockerMac/main/install.sh | bash
```

O desde una copia del repositorio:

```bash
git clone https://github.com/rubo88/BitlockerMac.git
cd BitlockerMac
./install.sh
```

El instalador:

1. comprueba los requisitos;
2. instala con Homebrew lo que falte: macFUSE (te pedirá la contraseña del Mac), dislocker y ntfs-3g;
3. si tu macFUSE es anterior a la 5.5, te pregunta si quieres actualizarla para poder escribir: con Homebrew si ya tiene la 5.5 estable, o si no la 5.5.0 de prueba desde GitHub, tras comprobar su suma, la firma del desarrollador y la notarización de Apple. Por defecto no la instala;
4. compila la app y la instala en `~/.local/bin/BitlockerMac`;
5. registra un LaunchAgent para que arranque al iniciar sesión.

Vuelve a ejecutarlo cuando quieras para actualizar.

### Un paso a mano (solo una vez)

Activa la extensión de macFUSE en **Ajustes del Sistema → General → Ítems de inicio y extensiones → Extensiones del sistema de archivos (ⓘ) → macFUSE**. El instalador abre ese panel la primera vez. Sin ella, la app avisa con un mensaje al intentar desbloquear.

## Uso

1. Conecta el disco. En el menú del icono aparecerá «Desbloquear *nombre del disco* · *tamaño*…».
2. Escribe la contraseña de BitLocker o la clave de recuperación y pulsa **Desbloquear**.
3. La primera vez tras conectar el disco, la app te pide también la **contraseña del Mac** (ver [Seguridad](#seguridad)).
4. El disco se abre en Finder. El icono pasa a candado abierto.
5. Cuando acabes, **Expulsar** desde el menú. Después ya puedes desenchufarlo.

### Escritura (experimental)

Marca **Permitir escritura** en la ventana de desbloqueo. Ten en cuenta:

- **Expulsa siempre desde el menú antes de desenchufar.** La escritura pasa por dos capas FUSE; un tirón del cable puede perder datos.
- Si el disco viene de un Windows que no se apagó del todo (inicio rápido o hibernación), no se abre en escritura para no dañarlo. Apaga Windows con Mayúsculas + «Apagar», o ábrelo en solo lectura.
- Haz copia de lo importante antes de empezar a usarlo.

### Idioma

La interfaz sigue el primer idioma del Mac. Para fijarla:

```bash
defaults write io.github.rubo88.BitlockerMac language es   # o en, o auto
```

y reinicia la app (Salir en el menú y `launchctl kickstart gui/$(id -u)/io.github.rubo88.BitlockerMac`, o cierra sesión).

## Cómo funciona

1. **Permiso sobre el disco.** macFUSE en modo FSKit solo monta como usuario normal, no como root, así que dislocker no puede ejecutarse como administrador. Con tu contraseña del Mac, la app (vía `sudo`) hace a tu usuario propietario de la partición cifrada (`/dev/diskXsY`) con permiso de solo lectura (o lectura y escritura si lo pides). macOS lo deshace al desconectar el disco.
2. **Descifrar.** `dislocker-fuse` descifra la partición y deja el volumen descifrado como un fichero virtual en `~/Library/Caches/BitlockerMac/<diskXsY>/dislocker-file`.
3. **Montar.** En solo lectura, `hdiutil` adjunta ese fichero y macOS lo monta con su propio soporte NTFS/exFAT. En escritura, `ntfs-3g` lo monta en `/Volumes` (o `hdiutil` en escritura si es exFAT/FAT).

## Seguridad

- **La clave de BitLocker nunca va en la línea de comandos** (que cualquier usuario del Mac puede ver con `ps`) **ni en ningún registro**. La contraseña se pasa a dislocker por la variable de entorno `DISLOCKER_PASSWORD` (el entorno de un proceso solo lo ven tu usuario y root). La clave de recuperación se teclea en un pseudoterminal sin eco, porque dislocker solo la lee de un terminal.
- **La contraseña del Mac** solo se usa para el cambio de permisos de la partición, con `sudo` y una ventana propia de la app.
- Mientras el disco está conectado, la partición cifrada es legible por tu usuario. Está cifrada, así que sin la clave no se puede leer nada.
- El registro (`~/Library/Logs/BitlockerMac.log`) solo guarda qué se hizo y los errores, nunca claves.

## Limitaciones

- La vía de la **clave de recuperación** aún no se ha probado con una clave real; la contraseña sí.
- La escritura es experimental: probada con imágenes NTFS de prueba y con discos reales poco.
- macFUSE 5.5 no monta en `/Volumes` nombres con caracteres no ASCII: en escritura, la app quita tildes y eñes del nombre de la carpeta de montaje.
- Solo discos externos.

## Desinstalar

```bash
./uninstall.sh
```

Desde una copia del repositorio, o borra a mano `~/.local/bin/BitlockerMac` y `~/Library/LaunchAgents/io.github.rubo88.BitlockerMac.plist` (tras `launchctl bootout gui/$(id -u)/io.github.rubo88.BitlockerMac`). macFUSE, dislocker y ntfs-3g se quedan instalados; el script dice cómo quitarlos.

## Licencia

MIT. BitLocker es una marca de Microsoft; este proyecto no tiene relación con Microsoft.
