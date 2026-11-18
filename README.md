# Personal Scoop Bucket

```powershell
scoop bucket add personal https://github.com/ripg/personal-bucket.git
```

将应用 manifest 保存到 `bucket/<app>.json`，然后用 `scoop install personal/<app>` 安装。为需要自动更新的应用配置 `checkver` 和 `autoupdate`。 [Scoop 自动更新文档](https://github.com/ScoopInstaller/Scoop/wiki/App-Manifest-Autoupdate)

GitHub Actions 每 6 小时检查上游版本，并将生成的 manifest 更新提交到默认分支。也可以在 **Actions → Update Scoop manifests → Run workflow** 手动启动。
