@echo off
chcp 65001 >nul
cd /d "%~dp0"
echo 启动屏幕采集工作台。关闭此窗口即可退出。
echo 控制台地址：http://127.0.0.1:8788
Screen.App.exe
pause
