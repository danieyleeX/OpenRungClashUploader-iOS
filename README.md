# OpenRungClashUploader-iOS

独立的 SwiftUI iPhone 应用项目，不依赖或修改 Windows 版本。

## 功能

- 从 OpenRung Broker 获取并验证签名的节点目录，生成 Mihomo YAML（最多请求 10 个节点）。
- 获取 Zhuhai Clash YAML。
- 查看、编辑和复制前预览 YAML；上传时覆盖远程目标文件。
- FTP 设置可修改，默认路径为 `wwwroot/clash.asp`；FTP 密码存储在 iOS Keychain。
- FTP 浏览目录、上传文件、新建目录、删除文件/目录。
- 中国 GeoSite/GeoIP 与局域网直连规则。

## 打开

在 Mac 上用 Xcode 14.2 打开 `OpenRungClashUploader-iOS.xcodeproj`。项目使用 Swift 5 语言模式和 iOS 16.2 部署目标，系统框架调用限制在 Xcode 14.2 / iOS 16.2 SDK 范围内。

当前开发环境没有 macOS/Xcode，因此尚未在 Xcode 中编译或连接 FTP/Broker 实测。Xcode 14.2 自带的设备支持无法直接调试 iOS 27.2 的 iPhone；要在这台手机上运行调试仍需新版 Xcode。FTP 是明文 FTP 协议；服务器需允许被动模式（EPSV/PASV）。
