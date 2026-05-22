# Brandmen Ads Player (Android)

Простой плеер для Android-планшетов: проигрывает видео из выбранной папки
по очереди, синхронизируется с Mac-сервером Brandmen Control через HTTP.

## Структура

```
src/com/brandmen/ads/
  MainActivity.java   — основной экран, плеер, синхронизация, настройки
  BootReceiver.java   — авто-запуск при включении планшета

resources/
  AndroidManifest.xml — манифест с разрешениями (INTERNET, MANAGE_EXTERNAL_STORAGE)
  resources.arsc       — заглушка ресурсов

release.keystore       — ключ для подписи (пароль brandmen123)
```

Сборка происходит автоматически через `.github/workflows/build-android.yml`.
APK подписывается v1+v2+v3 схемами для совместимости с Android 7+.

## Установка на планшет

Подробная инструкция в `Brandmen-Setup/APK-для-планшетов/УСТАНОВКА.txt`
или в корневом `README.md`.
