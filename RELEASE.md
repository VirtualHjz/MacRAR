# MacRAR 发布检查

## 本地验证

```bash
./Scripts/create_icon.sh
./Scripts/test_release.sh
./Scripts/build_app.sh release
codesign --verify --deep --strict --verbose=2 dist/MacRAR.app
hdiutil verify dist/MacRAR-1.0.0-arm64.dmg
```

成品位于 `dist/MacRAR.app` 和 `dist/MacRAR-1.0.0-arm64.dmg`。当前构建仅包含 Apple Silicon (`arm64`)，最低系统版本为 macOS 14。

## 公开分发

默认脚本采用临时 ad-hoc 签名，适合本机功能验证。公开分发前，使用 Developer ID Application 证书重新构建，例如：

```bash
CODE_SIGN_IDENTITY="Developer ID Application: <组织名称> (<Team ID>)" ./Scripts/build_app.sh release
```

然后使用 Apple 公证服务提交 DMG、等待通过并装订公证票据：

```bash
xcrun notarytool submit dist/MacRAR-1.0.0-arm64.dmg --keychain-profile "<公证凭据配置名>" --wait
xcrun stapler staple dist/MacRAR-1.0.0-arm64.dmg
```

最后在干净的 macOS 安装环境验证 Gatekeeper。当前环境只有 Apple Development 证书，因此尚未完成上述步骤。

内置 7za 版本为 16.02，不支持 Zstandard；创建格式列表已隐藏该格式，打开 Zstandard 文件时会明确提示不支持。RAR 创建依赖用户另行安装的 RARLAB `rar` 命令行工具。
