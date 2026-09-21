Ты — senior DevOps/Windows automation engineer. Твоя задача — самостоятельно разработать готовый к использованию PowerShell-инструмент для автоматизированного обновления ПО SePlatform/Systeme Soft на Windows-машинах клиента.

## 1. Цель

Нужно создать универсальный интерактивный deployment tool, который запускается непосредственно на машине клиента без Git, Ansible и других внешних систем.

Исходный архив:

```text
X:\HMI 2.0.38.zip
```

Архив содержит несколько десятков MSI-компонентов SePlatform разных продуктов и версий.

Инструмент должен:

1. Проанализировать машину.
2. Найти установленные компоненты SePlatform.
3. Проанализировать MSI в архиве.
4. Сопоставить установленные компоненты с пакетами из архива.
5. Проверить зависимости.
6. Сформировать план изменений.
7. Если компонент отсутствует — спросить пользователя, устанавливать ли его.
8. Если старая версия установлена — автоматически удалить её и установить новую.
9. Не трогать постороннее ПО.
10. Проверить результат после установки.
11. Создать подробные логи.
12. Быть идемпотентным: повторный запуск не должен повторно устанавливать уже актуальные компоненты.

Главный принцип:

**никаких предположений и массового удаления/установки по имени `SePlatform*`. Только явно разрешённые компоненты из manifest.**

---

# 2. Сначала исследуй окружение

Перед написанием кода самостоятельно исследуй:

```text
X:\HMI 2.0.38.zip
```

Не предполагай структуру ZIP.

Распакуй архив во временную директорию и найди:

* все MSI;
* документацию;
* compatibility-файлы;
* README/ВАЖНО-файлы;
* возможные инструкции по установке;
* зависимости;
* требования к .NET;
* требования к Python;
* архитектуру;
* локализацию;
* порядок/особенности обновления, если они указаны.

Особенно изучи:

```text
HMI-2.0.38 - лист совместимости.txt
ВАЖНО! ОБЯЗАТЕЛЬНО К ПРОЧТЕНИЮ.md
```

Если файлы находятся в другом месте — найди их автоматически.

Также исследуй MSI, если это возможно:

* ProductName
* ProductVersion
* ProductCode
* UpgradeCode
* архитектуру
* Launch Conditions
* зависимости
* свойства MSI

Не используй `Win32_Product` для инвентаризации установленного ПО, поскольку он может инициировать MSI repair и работает медленно.

Используй Registry:

```text
HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*
HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*
```

При необходимости используй Windows Installer COM API для анализа MSI.

---

# 3. Архитектура проекта

Создай проект:

```text
SePlatform-Deploy/
│
├── Deploy.ps1
├── manifest.json
├── config.json
├── README.md
│
├── logs/
│
└── modules/
    ├── Inventory.ps1
    ├── Manifest.ps1
    ├── Versioning.ps1
    ├── Dependencies.ps1
    ├── Installer.ps1
    ├── Uninstaller.ps1
    ├── Verification.ps1
    └── Logging.ps1
```

Если считаешь модульную структуру избыточной для первой версии — можешь использовать меньше файлов, но архитектура должна оставаться понятной и поддерживаемой.

Главный entry point:

```text
Deploy.ps1
```

---

# 4. Manifest

Создай `manifest.json`.

В нём должен быть **явный whitelist** всех компонентов, которые разрешено устанавливать/обновлять.

Не используй:

```powershell
Get-ChildItem *.msi
```

с последующей установкой всего найденного.

Каждый компонент должен быть описан явно.

Например:

```json
{
  "products": [
    {
      "id": "DataServer",
      "displayName": "SePlatform.Data Server",
      "installerPattern": "SePlatform.Server-*.msi",
      "architecture": "x64",
      "required": true
    }
  ]
}
```

Но перед созданием manifest обязательно изучи реальное содержимое ZIP и реальные названия установленных продуктов.

Manifest должен содержать как минимум:

* ID компонента;
* ожидаемый DisplayName;
* шаблон MSI;
* архитектуру;
* локализацию, если применимо;
* минимальные/ожидаемые версии;
* обязательность;
* зависимости.

Не придумывай значения, которые можно определить из архива или установленного ПО.

---

# 5. Компоненты

В архиве находятся, среди прочего:

### Data Server

```text
SePlatform.AccessPoint
SePlatform.Imitator
SePlatform.Server
```

### Development Studio

```text
seplatform.devstudio
```

### Domain

```text
seplatform.domain
```

### HMI

```text
seplatform.hmi.desktop
seplatform.hmi.webviewer
```

### HMI components

```text
HMI.AdminConsole
HMI.Alarms
HMI.Charts
HMI.CommonLib
HMI.ComtradeViewer
HMI.Explorer
HMI.Formats
HMI.IntegrityControl
HMI.Security
HMI.SecurityConfigurator
HMI.SetPoints
HMI.Statistics
HMI.SystemLogViewer
HMI.Tables
HMI.Trends
```

### Historian

```text
seplatform.historian
```

### Licensing

```text
SePlatform.LicenseServer.Agent
```

### Mapping Server

```text
SePlatform.MapServer
```

### Security

```text
seplatform.security
```

### Tools

```text
seplatform.tools
```

Но это только ориентир.

**Фактический список должен быть получен из ZIP.**

---

# 6. Что НЕ устанавливать

В Windows deployment должны использоваться только подходящие MSI.

Игнорировать:

```text
.deb
.rpm
.zip
.msm
.txt
.md
.docx
```

`.msm` не является самостоятельным установщиком.

Не устанавливать и не изменять:

* 7-Zip;
* .NET;
* Python;
* Visual C++ Redistributable;
* OpenLDAP;
* VMware Tools;
* Wireshark;
* Edge/WebView2;
* OPC;
* другое стороннее ПО.

Даже если эти программы найдены в системе.

---

# 7. Inventory

Создай функцию инвентаризации.

Она должна получить:

```text
DisplayName
DisplayVersion
Publisher
InstallLocation
UninstallString
QuietUninstallString
WindowsInstaller
PSChildName
RegistryPath
```

для установленных SePlatform-компонентов.

Не ограничивайся одним Registry path — проверь обе архитектуры Registry.

---

# 8. Сравнение версий

Версии могут выглядеть так:

```text
2.4.36+b4.r151051
```

а Registry может возвращать:

```text
2.4.34.1
```

Нельзя сравнивать такие версии обычным:

```powershell
[version]"..."
```

если формат несовместим.

Создай нормализатор версии.

Нужно учитывать:

```text
major
minor
patch
build
revision
```

Если в архиве:

```text
2.4.36+b4.r151051
```

а установлено:

```text
2.4.34.1
```

должно определиться:

```text
UPDATE
```

Если версии одинаковые:

```text
SKIP
```

Если установленная версия новее архива:

```text
SKIP + WARNING
```

Никогда автоматически не делай downgrade.

---

# 9. Отсутствующие компоненты

Если компонент отсутствует, его нельзя автоматически устанавливать.

Сформируй список:

```text
Отсутствующие компоненты:

[1] HMI.AdminConsole 1.1.0
[2] HMI.Statistics 1.2.1
[3] HMI.Trends 3.2.1
[4] Mapping Server 1.5.1
```

Затем:

```text
Выберите компоненты для установки:
1,3,4
```

Поддержать:

```text
A = все
N = ничего
```

Также корректно обработать:

```text
1, 3, 4
1 3 4
1,3
```

Проверять некорректный ввод.

---

# 10. План перед выполнением

До любых изменений показать пользователю план:

```text
SePlatform Deployment Tool
==========================

Archive:
X:\HMI 2.0.38.zip

OS:
Windows 11 x64

Changes:

[UPDATE] Data Server
         2.4.34.1 -> 2.4.36

[UPDATE] Development Studio
         2.2.3.20 -> 2.2.5

[UPDATE] HMI
         2.0.36.19 -> 2.0.38.101

[OK] HMI.ComtradeViewer
     2.0.0.9

[SKIP] SomeComponent
       installed version is newer

Missing:

[1] HMI.AdminConsole 1.1.0
[2] HMI.Statistics 1.2.1

Select: 1,2 / A / N

Dependencies:

[OK] .NET ...
[OK] Python 3 ...

================================
Continue? [Y/N]
```

Требуется **один основной запрос подтверждения**, а не подтверждение каждого MSI.

---

# 11. Dependencies

Проверить реальные зависимости на основании:

* compatibility documentation;
* MSI LaunchConditions;
* MSI properties;
* установленных компонентов.

Особенно проверить:

```text
.NET
Python 3
```

Но:

**не устанавливать автоматически отсутствующие .NET/Python.**

Если зависимость отсутствует:

```text
[ERROR] HMI requires Python 3.x
```

и соответствующий компонент не устанавливать.

Если возможно определить конкретную минимальную версию — использовать её.

Не придумывать минимальные версии.

Если MSI сам содержит LaunchCondition, учитывать её как дополнительный уровень проверки.

---

# 12. MSI installation

Установка должна выполняться через:

```powershell
msiexec.exe /i "package.msi" /qn /norestart /l*v "install.log"
```

Обязательно:

* ждать завершения;
* получать `$LASTEXITCODE`;
* сохранять exit code;
* сохранять MSI log;
* корректно обрабатывать `0`;
* корректно обрабатывать `3010`;
* обрабатывать ошибки.

Не показывать GUI MSI.

---

# 13. Uninstall

Старый компонент перед обновлением удалить автоматически.

Использовать MSI ProductCode / Registry uninstall information.

Предпочтительный вариант:

```powershell
msiexec.exe /x {PRODUCT-CODE} /qn /norestart /l*v "uninstall.log"
```

Не использовать:

```powershell
Win32_Product
```

для удаления.

Если uninstall завершается ошибкой:

```text
ERROR
```

то новую версию этого компонента НЕ устанавливать.

---

# 14. Running processes/services

Перед uninstall выяснить, есть ли у SePlatform:

* Windows Services;
* процессы;
* службы, которые могут блокировать MSI.

Не завершать процессы по широкому условию вроде:

```text
*Se*
```

Работать только с конкретными известными компонентами.

Если из документации/системы можно определить необходимые services/processes — аккуратно добавить остановку и последующий запуск.

Если достоверно определить это невозможно — не придумывать.

---

# 15. Verification

После каждой установки повторно выполнить inventory.

Проверить:

```text
DisplayName
DisplayVersion
```

Например:

```text
Installed:
SePlatform.HMI x64
2.0.38.101

Expected:
2.0.38.101

[OK]
```

Если версия не соответствует:

```text
[ERROR] Verification failed
```

---

# 16. Logs

Создавать отдельную директорию на каждый запуск:

```text
C:\ProgramData\SePlatform\Deployment\YYYY-MM-DD_HH-mm-ss\
```

Например:

```text
Deployment.log

DataServer-uninstall.log
DataServer-install.log

HMI-uninstall.log
HMI-install.log

Historian-install.log

report.json
```

Логировать:

* время;
* компонент;
* старую версию;
* новую версию;
* действие;
* MSI path;
* exit code;
* результат;
* ошибку.

---

# 17. Dry Run

Обязательно реализовать:

```powershell
.\Deploy.ps1 -Archive "X:\HMI 2.0.38.zip" -WhatIf
```

В этом режиме:

* ничего не удалять;
* ничего не устанавливать;
* не менять систему;
* только inventory;
* dependency check;
* plan.

Вывод должен показывать, что произошло бы.

---

# 18. Parameters

Минимально:

```powershell
.\Deploy.ps1 -Archive "X:\HMI 2.0.38.zip"
```

и:

```powershell
.\Deploy.ps1 -Archive "X:\HMI 2.0.38.zip" -WhatIf
```

Дополнительно можно реализовать:

```text
-LogPath
-NonInteractive
-AutoApprove
```

если это не усложняет проект.

---

# 19. Administrator

Проверять elevation в самом начале.

Если PowerShell не запущен от Administrator:

```text
ERROR: This deployment requires Administrator privileges.
```

Можно предложить перезапустить PowerShell с elevation, но не делать неожиданный UAC restart без понятного сообщения.

---

# 20. ZIP handling

Не устанавливать MSI непосредственно из ZIP.

Распаковать нужные MSI во временную директорию:

```text
%TEMP%\SePlatform-Deploy\<timestamp>\
```

или другую безопасную рабочую директорию.

После успешного выполнения временные файлы удалить.

При ошибке оставить их для диагностики либо дать параметр для сохранения.

---

# 21. Безопасность

Критически важно:

НЕЛЬЗЯ:

```powershell
Get-ChildItem *.msi | foreach { msiexec ... }
```

НЕЛЬЗЯ:

```powershell
Get-CimInstance Win32_Product
```

НЕЛЬЗЯ:

```powershell
Get-ChildItem Registry:\... | Where DisplayName -like "*SePlatform*" | uninstall everything
```

НЕЛЬЗЯ автоматически делать downgrade.

НЕЛЬЗЯ автоматически устанавливать сторонние зависимости.

НЕЛЬЗЯ удалять конфигурационные файлы.

Обычный MSI uninstall должен использовать штатное поведение MSI, которое сохраняет пользовательские конфигурации, если сам пакет их не удаляет.

---

# 22. Idempotency

После успешного deployment повторный запуск:

```powershell
.\Deploy.ps1 -Archive "X:\HMI 2.0.38.zip"
```

должен показать:

```text
[OK] Data Server
[OK] Development Studio
[OK] HMI
[OK] Historian
...
```

и не выполнять uninstall/install без необходимости.

---

# 23. Error handling

Если один независимый компонент не установился:

```text
[ERROR] HMI.Charts
```

продолжить остальные компоненты, если это безопасно.

В конце:

```text
Deployment completed with errors.
Successful: 25
Skipped: 4
Failed: 1
```

и вернуть ненулевой exit code.

Если ошибка dependency/security/critical prerequisite делает дальнейшее выполнение небезопасным — остановить deployment.

---

# 24. Final report

В конце показать:

```text
========================================
DEPLOYMENT SUMMARY
========================================

Updated:   18
Installed: 3
Skipped:   7
Failed:    1

[OK] Data Server
[OK] Development Studio
[OK] HMI
[OK] Historian
[SKIP] ComtradeViewer
[ERROR] HMI.Charts

Logs:
C:\ProgramData\SePlatform\Deployment\...

Exit code: 1
```

Также сохранить `report.json`.

---

# 25. README

Создай README с:

* назначением;
* требованиями;
* запуском;
* примером `-WhatIf`;
* описанием manifest;
* описанием логов;
* exit codes;
* ограничениями;
* инструкцией для оператора на объекте.

README должен быть понятен инженеру, который впервые использует инструмент.

---

# 26. Не задавай лишних вопросов

Сначала самостоятельно исследуй доступные файлы, ZIP и систему.

Если какая-то информация действительно отсутствует, зафиксируй её как TODO/конфигурационный параметр, а не придумывай значение.

Не делай архитектуру сложнее необходимого.

Главный приоритет:

**надёжность > универсальность > красота кода.**

Инструмент будет использоваться на реальных клиентских машинах, поэтому любые потенциально опасные действия должны быть явно ограничены whitelist и логироваться.

---

# 27. Результат

В итоге предоставь полностью готовый проект:

```text
SePlatform-Deploy/
```

с рабочими:

```text
Deploy.ps1
manifest.json
config.json
README.md
modules/*
```

Проверь синтаксис PowerShell.

Проверь все пути.

Проверь JSON.

Проверь обработку ошибок.

Проверь режим `-WhatIf`.

Проверь, что скрипт не использует `Win32_Product`.

Проверь, что он не может случайно удалить стороннее ПО.

Проверь идемпотентность.

Если возможно, проведи безопасный dry-run на текущей машине без изменения установленного ПО.

После создания проекта покажи:

1. структуру файлов;
2. кратко архитектуру;
3. как запускать;
4. какие места требуют реального тестирования на клиентской машине;
5. полный код созданных файлов.
