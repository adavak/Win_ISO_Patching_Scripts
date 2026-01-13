### Win_ISO_Patching_Scripts

[中文说明](https://github.com/adavak/Win_ISO_Patching_Scripts/blob/master/README_cn.md)

[English Readme](https://github.com/adavak/Win_ISO_Patching_Scripts/blob/master/README.md)

<a href="https://github.com/adavak/Win_ISO_Patching_Scripts/releases/latest"><img src="https://img.shields.io/github/v/release/adavak/Win_ISO_Patching_Scripts"></a>
<a href="https://github.com/adavak/Win_ISO_Patching_Scripts/releases/latest"><img src="https://img.shields.io/github/release-date-pre/adavak/Win_ISO_Patching_Scripts"></a>

##### 用法：把 Windows 映像（ISO 格式）放入文件夹根目录，运行 Start.cmd 开始下载最新补丁并开始制作集成补丁的 ISO。下载补丁文件地址为微软官方。

###### 支持的 Windows 版本：

|名称|内部版本（最后更新：2026年1月14日）|
|---|---|
|**Windows 10 企业版 LTSB 2016、Windows Server 2016**|**Build 14393.8783**|
|**Windows 10 企业版 LTSC 2019、Windows Server 2019**|**Build 17763.8276（2024-6，Arm 版本生命终止）**|
|**Windows 10 22H2、Windows 10 企业版 LTSC 2021**|**Build 1904x.6809**|
|**Windows Server 2022**|**Build 20348.4529**|
|**Windows 11 23H2**|**Build 22631.6491**|
|**Windows Server 2025**|**Build 26100.32230**|
|**Windows 11 25H2、Windows 11 企业版 LTSC 2024**|**Build 26200.7623**|

###### 一些设置（位于文件夹根目录 W10UI.ini）：
|值（预设）|说明|
|---|---|
|**Net35 = 1**|若不想集成 .net 3.5。请改成0|
|**wim2esd = 1**|若不想生成 install.esd 减少空间占用。耗费大量的时间和计算机资源，映像尺寸缩小25%左右。请改成0|
|**AutoStart = 1**|对于多版本映像，脚本默认集成全部映像并自动开始，如需选择映像内的特殊版本，比如只选择生成专业版的集成更新映像等。请改成0。（脚本运行后，按"8"选择版本，可以选择多个版本，选择好后按"0"开始。）|
|**ltscfix = 1**|对 LTSC 2021 和 2024 的库文件修复（官方修正后移除此选项），如不想修复。请改成0|
|**netfx481 = 1**|对 .net framework 4.8.1 的支持，如不想安装。请改成0|
|**nosuggapp = 0**|若想禁用 Windows 全新安装后擅自安装三方 App。请改成1|
|**nosuggtip = 0**|若想禁用 Windows 在各处无用的建议提示和功能。请改成1|
|**norestorage = 0**|若想禁用保留存储的空间占用。请改成1|
|**nogamebar = 0**|若想禁用游戏栏 Game Bar。请改成1|
|**oobebypass = 0**|若想禁用在线账号，并启用本地帐号创建。请改成1|

###### 感谢：
|工具|源|
|---|---|
|**7-zip**|[7-zip.org](https://www.7-zip.org)|
|**wimlib**|[wimlib.net](https://wimlib.net)|
|**aria2**|[aria2](https://github.com/aria2/aria2)|
|**oscdimg**|[Microsoft](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/oscdimg-command-line-options)|
|**PSFExtractor**|[PSFExtractor](https://github.com/Secant1006/PSFExtractor)|
|**W10UI**|[BatUtil](https://github.com/abbodi1406/BatUtil)|
