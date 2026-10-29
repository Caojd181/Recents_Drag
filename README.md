# Recents Drag

让 macOS Dock「最近使用」中的文件可以直接拖到文件夹或应用窗口，完成复制或添加附件，保留系统原生的展开界面。

## 下载

[下载 Recents Drag 0.9（Apple Silicon / arm64，DMG）](https://github.com/Caojd181/Recents_Drag/releases/download/v0.9.0/Recents-Drag-0.9-arm64.dmg) · [版本说明与历史版本](https://github.com/Caojd181/Recents_Drag/releases)

## 介绍视频

https://github.com/user-attachments/assets/16764513-2cfb-4185-8ce2-fde73a13d15d

## 安装与授权

面向 Apple Silicon（M 系列）Mac，macOS 14 及以上；目前仅在 macOS 26.3 实测。使用前，Dock 中需已有原生「最近使用」入口。

1. 从 [Releases](https://github.com/Caojd181/Recents_Drag/releases) 获取 DMG 安装包，将 **Recents Drag** 拖入 Applications，然后打开 App。
2. 在「系统设置 → 隐私与安全性 → 辅助功能」中添加并开启 Recents Drag。
3. 在控制窗口点击「添加文件夹…」，选择文件实际所在的「下载」「文稿」「桌面」或工作目录，可以多选。**不要只选择用户主目录。**
4. 展开 Dock「最近使用」，从文件图标中心拖到目标文件夹或支持文件拖放的应用中。

当前版本未经过 Apple 公证。若 macOS 拦截打开，可在「系统设置 → 隐私与安全性」中针对本 App 选择「仍要打开」。更新前请先完全退出旧版；若新版仍提示未授权，请在辅助功能设置中移除旧条目，再添加当前 App。

## 日常使用

- **工作文件夹**：点击「编辑」可修改路径，每行一个，保存后生效；新增目录可能需要系统确认访问权限。「忘记」清除已记住的目录。
- **关闭窗口**：继续在后台运行，默认隐藏 App 的 Dock 图标；再次打开 App 即可找回控制窗口。
- **暂停 / 完全退出**：暂停停止拖动辅助，点击「继续运行」恢复；完全退出结束后台进程。
- **蓝色拖动框**：默认关闭，需要检查拖动区域时再开启。

拖到文件夹时提供复制操作，原文件保留；接收应用需支持文件拖放。

## 部分文件无法拖动？

请先确认已直接授权文件所在目录。App 只处理授权范围内、符合系统最近使用查询且已进入索引的最新 **100** 条结果；系统索引内部仍可能匹配更多候选。未索引、超出范围或尚未下载的云端文件可能无法拖动。同名文件可能无法区分，请核对拖出的文件。

## 隐私与卸载

App 在本地运行，无联网上传或遥测功能，不安装开机启动项。仅保存目录授权记录和偏好；手动导出的诊断可能包含文件名、路径，请按需保管。

卸载前点击「忘记」，再点击「完全退出」，随后将 Applications 中的 App 移到废纸篓。需要清空配置时，另删除以下位置，并在系统辅助功能设置中移除 App：

```text
~/Library/Application Support/RecentsDragDemo/
~/Library/Preferences/com.caojd.RecentsDragDemo.plist
```

手动导出的诊断文件需自行删除；macOS 管理的其他系统记录可能保留。

## 许可与商业授权

本项目以源码可见（source-available）方式发布，采用 [PolyForm Noncommercial License 1.0.0](LICENSE)。**非商业用途免费；商业用途须事先取得著作权人的另行书面授权，许可证已明确允许的情形除外。**

完整权利与义务以 [LICENSE](LICENSE) 为准。商业授权请通过本项目仓库联系著作权人。
