支持 Windows 版本：14393、17763、19044、20348、22000。

运行 Start.cmd 开始下载最新补丁并开始制作集成补丁的 ISO。下载补丁文件地址为微软官方。

一些设置（位于文件夹根目录 W10UI.ini）；

Net35 = 1（若不想集成 .net 3.5，请改成0）
wim2esd =1（若不想生成 install.esd 减少空间占用。耗费大量的时间和计算机资源，镜像尺寸缩小25%左右，请改成0）；

脚本默认集成全部镜像，如需选择镜像内的特殊版本，比如只选择生成专业版的集成更新镜像等，请修改 W10UI.ini 内 #24 内容 "AutoStart     =1" 为 "AutoStart     =0"

新增对 LTSC 2021 的库文件修复（官方修正后移除此选项），如不想修复，请修改 W10UI.ini 内 #26 内容 "ltscfix     =1" 为 "ltscfix     =0"

脚本运行后，按"8"选择版本，可以选择多个版本，选择好后按"0"开始。

Tools:
7-zip (7-zip.org)
wimlib (wimlib.net)
aria2 (github.com/aria2/aria2)
oscdimg (Microsoft)
PSFExtractor (betaworld.cn)

Script:
W10UI (abbodi1406@MDL)
