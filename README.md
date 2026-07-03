# 3x-ui autoinstaller (Reality + gRPC/XHTTP/WS)

Автоустановщик для 3x-ui под Ubuntu 22.04/24.04. Скрипт сам определяет систему и IP, ставит свежий 3x-ui без ручного ввода, выпускает сертификат Let's Encrypt для `<ipv4>.sslip.io`, включает HTTPS для панели через `x-ui cert`, настраивает Nginx как TLS-фронт для трёх входящих, а затем создаёт 4 VLESS inbound'а и сохраняет все данные для подключения.

## Установка

Рекомендуемый способ (работает и под root, и через sudo; меню выбора языка EN/RU остаётся интерактивным):

```bash
curl -Ls https://raw.githubusercontent.com/StraitBowyer/wqyuwymd/main/install.sh -o 3xui.sh && sudo bash 3xui.sh
```

Если вы уже под root, можно короче через процесс-подстановку:

```bash
bash <(curl -Ls https://raw.githubusercontent.com/StraitBowyer/wqyuwymd/main/install.sh)
```

> Не запускайте `sudo bash <(curl ...)`: sudo не пробрасывает файловый дескриптор
> процесс-подстановки, и bash упадёт с ошибкой `/dev/fd/63: No such file or directory`.
> Используйте вариант со скачиванием в файл или без `sudo`, если вы уже root.

Полностью неинтерактивный запуск (язык задаётся переменной `XUI_LANG`, `ru` или `en`):

```bash
curl -Ls https://raw.githubusercontent.com/StraitBowyer/wqyuwymd/main/install.sh -o 3xui.sh && sudo XUI_LANG=ru bash 3xui.sh
```

## Требования

- Ubuntu 22.04 или 24.04
- запуск от root
- открытый порт 80 для выпуска сертификата
- открытые порты 8443, 2087, 2083 и 2096
- открытый порт панели 2053

## Что будет установлено

- последняя версия 3x-ui в неинтерактивном режиме
- сертификат Let's Encrypt для `<ipv4>.sslip.io`
- HTTPS для панели через `x-ui cert`
- Nginx как TLS-фронт для трёх inbound'ов
- 4 VLESS inbound'а:
  - Reality TCP на `:8443` с `firefox` и `xtls-rprx-vision`
  - gRPC на `:2087` за Nginx с TLS
  - XHTTP на `:2083` за Nginx с TLS
  - WebSocket на `:2096` за Nginx с TLS

После установки все клиентские ссылки и учётные данные панели сохраняются в:

```text
/root/3xui-install-info.txt
```

## Как посмотреть доступы позже

- В самой панели: откройте меню `x-ui`
- Если нужно восстановить ссылки, смотрите файл `/root/3xui-install-info.txt`
- Для панели обычно достаточно повторно открыть сохранённые данные или посмотреть текущие параметры в меню `x-ui`

## Кратко

Этот установщик рассчитан на быстрый развёртывающий запуск без ручной настройки панельных и inbound-параметров. Если порт 80 занят или сертификат не получается выпустить, установка остановится и покажет причину.