# 这个 fork 怎么用

上游是 [ccch1mneyyy/dsh-Go](https://github.com/ccch1mneyyy/dsh-Go)。这个 fork 在 `main` 上
既有上游的全部历史，也带着自己的改动：

| 提交 | 内容 |
| --- | --- |
| `ci: build a complete APK …` | `build-apk.yml`：在 Linux runner 上构建内置运行时的完整 APK |
| `ci: default the flavor …` / `ANDROID_NDK_HOME` / `draft release` | 上面那个 workflow 的修复与下载优化 |
| `feat: offline wake word that opens a call` | 唤醒词：离线 KWS + 设置页 + 命中后进免手持通话 |
| `build: one signing identity per fork …` | CI 固定签名身份；`app_id_suffix` 让 fork 包与官方包并存 |

## 同步上游

仓库是浅克隆（`--depth 1`），第一次同步前要补全历史（约 660 MB，只需一次）：

```bash
git fetch --unshallow
```

之后每次同步：

```bash
git fetch upstream
git merge upstream/main          # 有冲突就解决后 git add + git commit
git push origin main
```

用 `merge` 而不是 `rebase`：冲突只需解决一次，`main` 的历史不会被重写，不用 `--force`。
GitHub 网页上的「Sync fork → Update branch」做的也是同一件事。

同步后想确认自己的改动还在：

```bash
git log --oneline upstream/main..main    # 应该看到上面那几个提交
```

## 构建与安装

```bash
gh workflow run build-apk.yml --ref main -f flavor=arm64
gh run watch
gh release download ci-apk-arm64-<N> --pattern "*.apk" -D out
adb install -r out/app-arm64-release.apk
```

- **版本号单调递增**：versionCode 是「构建分钟」（`tooling/build_number.py`），后构建的一定更大，
  所以永远能覆盖安装前一个。
- **签名固定**：workflow 用缓存里的 `~/.android/debug.keystore`（key `dsh-fork-debug-keystore-v1`）。
  缓存被 GitHub 清掉（长期不构建）就会换钥匙，届时只能卸载重装。想长期稳定就换成正式密钥：
  把 keystore 存成 repository secret，workflow 里解出来写进 `app/android/key.properties`
  （字段见 `docs/release.md`）。
- **和官方 App 的关系**：签名不同，永远无法覆盖官方包。要并存就加 `-f app_id_suffix=.fork`，
  包名变成 `io.github.ccch1mneyyy.dsh_app.fork`，官方包的数据不受影响。
- **App 内的自动更新**：走的是官方发布通道（`update.json`），fork 版收不到；升级方式是重新下载
  新 APK 覆盖安装。
