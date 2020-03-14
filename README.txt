支持 Windows 版本：14393、17763、1836X、19041。

运行 Start.cmd 开始下载最新补丁并开始制作集成补丁的 ISO。下载补丁文件地址为微软官方。

一些设置（位于文件夹根目录 W10UI.ini）

Net35 = 1（若不想集成 .net 3.5，请改成0）
wim2esd =1（若不想生成 install.esd 减少空间占用。耗费大量的时间和计算机资源，镜像尺寸缩小25%左右，请改成0）

Supported Windows Version: 14393, 17763, 1836X, 19041.

Run Start.cmd to start downloading the latest patches and start making ISO that integrate patches. The download patch files is from Microsoft official.

Some settings (located in the folder root W10UI.ini)

Net35 = 1 (if you do not want to integrate .net 3.5, please change to 0)
wim2esd = 1 (If you don't want to generate install.esd to reduce space consumption. It takes a lot of time and computer resources, the image size is reduced by about 25%, please change to 0)

Tools:
7-zip (7-zip.org)
wimlib (wimlib.net)
aria2 (github.com/aria2/aria2)
oscdimg (Microsoft)

Script:
W10UI (abbodi1406@MDL)
