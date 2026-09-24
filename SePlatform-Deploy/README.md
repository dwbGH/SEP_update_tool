# SePlatform Deploy Tool

Автоматизированное развёртывание/обновление программного комплекса **SePlatform / Systeme Soft**
с ZIP-архива дистрибутива. Инструмент работает напрямую с машины клиента, не требует
Git/Ansible и не трогает постороннее ПО — только компоненты из явного whitelist (manifest).

Проект разделён на две независимые версии:

| Папка      | Платформа | Установщики | Точка входа | Модули/библиотеки                             |
|-----------|-----------|-------------|-------------|-----------------------------------------------|
| `windows/` | Windows   | MSI         | `Deploy.ps1`| `modules/` (PowerShell)                       |
| `linux/`   | Linux     | .deb (dpkg) | `Deploy.sh` | `lib/` (bash) + `ServerCopies.sh`             |

## Быстрый старт

- Windows: `cd windows` → `.\Deploy.ps1 -Archive "X:\HMI 2.0.38.zip"` (см. `windows/README.md`).
- Linux:   `cd linux` → `./Deploy.sh -a "/path/HMI 2.0.38.zip"` (см. `linux/README.md`).