@echo off
setlocal EnableDelayedExpansion
title Zipper v1.1

:: --- АВТО-АДМИН ---
net session >nul 2>&1
if %errorLevel% neq 0 (
    powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

:START
cd /d "%~dp0"
chcp 1251 >nul
cls
color 0f

:MENU
cls
echo.
echo  ========================================
echo   Z I P P E R  v1.1
echo  ========================================
echo.
echo  [1] XPRESS 4K   (Быстрое)
echo  [2] XPRESS 8K   (Стандарт)
echo  [3] XPRESS 16K  (Сильное)
echo  [4] LZX         (Максимум / Игры)
echo.
echo  [5] РАСЖАТЬ     (Отмена)
echo  [6] СПРАВКА     (ЧИТАТЬ ОБЯЗАТЕЛЬНО!)
echo  [0] ВЫХОД
echo.
echo  ========================================
echo   Нажмите цифру...
choice /C 1234560 /N /M ""

if errorlevel 7 exit
if errorlevel 6 goto INFO
if errorlevel 5 set "action=decompress" & goto SELECT_PATH
if errorlevel 4 set "alg=lzx" & set "action=compress" & goto SELECT_PATH
if errorlevel 3 set "alg=xpress16k" & set "action=compress" & goto SELECT_PATH
if errorlevel 2 set "alg=xpress8k" & set "action=compress" & goto SELECT_PATH
if errorlevel 1 set "alg=xpress4k" & set "action=compress" & goto SELECT_PATH
goto MENU

:SELECT_PATH
cls
echo.
echo  Z I P P E R
echo  ----------------------------------------
echo  [1] Выбрать папку (Окно)
echo  [2] Вставить путь вручную
echo  [0] Назад
echo.
choice /C 120 /N /M ""
if errorlevel 3 goto MENU
if errorlevel 2 goto MANUAL_INPUT
if errorlevel 1 goto GUI_INPUT
goto SELECT_PATH

:GUI_INPUT
cls
echo  Открываю окно...
set "target_dir="
set "ps_script=%temp%\zipper_gui.ps1"
echo Add-Type -AssemblyName System.Windows.Forms > "%ps_script%"
echo $f = New-Object System.Windows.Forms.FolderBrowserDialog >> "%ps_script%"
echo $f.ShowNewFolderButton = $false >> "%ps_script%"
echo $text = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('0J/QvtC20LDQu9GD0LnRgdGC0LAsINCy0YvQsdC10YDQuNGC0LUg0L/QsNC/0LrRgyDQtNC70Y8g0YHQttCw0YLQuNGP')) >> "%ps_script%"
echo $f.Description = $text >> "%ps_script%"
echo if ($f.ShowDialog() -eq 'OK') { Write-Host $f.SelectedPath } >> "%ps_script%"
for /f "usebackq delims=" %%I in (`powershell -ExecutionPolicy Bypass -File "%ps_script%"`) do set "target_dir=%%I"
del "%ps_script%" >nul 2>&1
if "%target_dir%"=="" goto SELECT_PATH
goto RUN_PROCESS

:MANUAL_INPUT
echo.
echo  Вставьте путь и нажмите Enter:
set "target_dir="
set /p "target_dir= > "
set "target_dir=%target_dir:"=%"
if "%target_dir%"=="" goto SELECT_PATH
if not exist "%target_dir%" goto SELECT_PATH
goto RUN_PROCESS

:RUN_PROCESS
cls
echo.
echo  ========================================
echo   ОБРАБОТКА...
echo  ========================================
echo  Папка: "%target_dir%"
echo.
pushd "%target_dir%" || (
    echo [ОШИБКА] Нет доступа.
    pause
    goto MENU
)

if "%action%"=="compress" (
    set "cmd_params=/c /s /a /i /f /exe:%alg%"
) else (
    set "cmd_params=/u /s /a /i /f /exe"
)

powershell -NoProfile -Command ^
  "$OutputEncoding = [Console]::OutputEncoding;" ^
  "cmd /c compact %cmd_params% * | ForEach-Object {" ^
  "  if ($_ -match 'ERR' -or $_ -match 'ОШИБКА' -or $_ -match 'LOCK') {" ^
  "    Write-Host $_ -ForegroundColor Red" ^
  "  } elseif ($_ -match ':' -and $_ -notmatch 'Total') {" ^
  "    Write-Host $_ -ForegroundColor Green" ^
  "  } else {" ^
  "    Write-Host $_ -ForegroundColor Gray" ^
  "  }" ^
  "}"

popd
echo.
echo  ========================================
echo   ГОТОВО.
echo  ========================================
pause
goto MENU

:INFO
cls
echo.
echo  ======================================================
echo                   ПОДРОБНАЯ СПРАВКА
echo  ======================================================
echo.
echo  ЧТО ЭТО ВООБЩЕ ТАКОЕ?
echo  Zipper использует функцию Windows "Compact OS".
echo  Файлы сжимаются физически, но для системы и игр они
echo  выглядят как обычные. Их НЕ НУЖНО распаковывать
echo  перед запуском. Все работает "на лету".
echo.
echo  1. КАКОЙ РЕЖИМ ЛУЧШЕ ДЛЯ ИГР?
echo     Однозначно [4] LZX.
echo     - Это самое мощное сжатие (экономия до 50%%).
echo     - Распаковка идет процессором очень быстро.
echo     - Если у вас медленный HDD, игры могут начать
echo       грузиться ДАЖЕ БЫСТРЕЕ.
echo.
echo  2. ЧТО ВЫБРАТЬ ДЛЯ ОБЫЧНЫХ ПРОГРАММ?
echo     [2] XPRESS 8K или [1] XPRESS 4K.
echo     Они сжимают слабее, но нагрузка на процессор
echo     практически нулевая. Идеально для офиса и софта.
echo.
echo  3. ПОЧЕМУ ТЕКСТ БЫВАЕТ КРАСНЫМ?
echo     Это значит, что файл (лог или конфиг) сейчас
echo     используется системой. Zipper просто пропускает
echo     его и идет дальше. Это НОРМАЛЬНО, не паникуйте.
echo.
echo  4. ЭТО БЕЗОПАСНО?
echo     Да. Это официальная функция Windows.
echo     Если вдруг игра станет тормозить (что вряд ли),
echo     просто выберите пункт [5] РАСЖАТЬ.
echo.
echo  ======================================================
echo  Нажмите любую клавишу, чтобы вернуться в меню...
pause >nul
goto MENU