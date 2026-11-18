# 这个 fork 怎么维护

上游是 [Sitoi/ClashBar](https://github.com/Sitoi/ClashBar)。本仓库只做两件事：
**在 `patched` 分支上维护定制修复**，以及**用一条工作流把它构建成可用的 DMG**。

## 分支模型

| 分支 | 内容 | 用途 |
| --- | --- | --- |
| `main` | 上游 `v0.3.6` 的镜像 | 只作为 rebase 的落点，不承载改动 |
| `patched` | `main` + 8 个定制 commit | 实际构建、发布、日常使用的分支 |

建议把默认分支改成 `patched`：

> Settings → Branches → Default branch → `patched`

原因：`workflow_dispatch` 只有在**默认分支**上存在该工作流文件时，才会在 Actions
页面出现 "Run workflow" 按钮。旧的做法是把 50 KB 的补丁塞进工作流、构建时
`git apply`，一冲突就整个发布流程失败；现在是源码即结果，工作流只负责构建。

## 发布

**打 tag（推荐）**

```bash
git tag v0.3.6-p1
git push origin v0.3.6-p1
```

会产出 `ClashBar-0.3.6-arm64.dmg`、`.dmg.sha256`，并创建同名 GitHub Release。
`CFBundleShortVersionString` 取 tag 去掉 `v` 和 `-` 后缀的部分（`v0.3.6-p1` → `0.3.6`），
`CFBundleVersion` 取 `github.run_number`。

**手动触发**：Actions → Release → Run workflow，可指定版本号、是否内嵌内核。

## 签名（可选，但建议）

不配置也能构建，产物是 adhoc 签名，本机自用没问题。配置之后：

- helper 的 XPC 客户端校验会从"签名里写了 `com.clashbar` 就放行"升级为
  `anchor apple generic and identifier "com.clashbar" and certificate leaf[subject.OU] = "<你的 TeamID>"`；
- 本机任意进程冒名 adhoc 签名成 `com.clashbar` 就能拿到 root 代理控制权的路径被堵住。

一次性配置：

1. **生成证书**：Xcode → Settings → Accounts → 选账号 → Manage Certificates →
   `+` → **Developer ID Application**。或 developer.apple.com → Certificates → `+`。
2. **导出 p12**：钥匙串访问 → 我的证书 → 找到
   `Developer ID Application: <你的名字> (<TEAMID>)` → 右键导出 → 设密码。
3. **取身份字符串**：

   ```bash
   security find-identity -v -p codesigning
   # "Developer ID Application: Nathan (ABCDE12345)"
   ```

4. **写进仓库 Secrets**（Settings → Secrets and variables → Actions）：

   | Secret | 值 |
   | --- | --- |
   | `MACOS_CERT_P12` | `base64 -i cert.p12 \| pbcopy` 的结果 |
   | `MACOS_CERT_PASSWORD` | 导出时设的密码 |
   | `MACOS_SIGNING_IDENTITY` | 第 3 步那一整串，含引号内的名字和括号 |

三个都缺省时走 adhoc；只配了证书却没配身份，工作流会直接报错，不会悄悄退化成未签名。

## 安装产物时注意

从 Release 下载的 DMG 带 `com.apple.quarantine`，因为**没有公证**，首次打开会被
Gatekeeper 拦。自用场景不需要公证，解掉隔离属性即可：

```bash
xattr -dr com.apple.quarantine /Applications/ClashBar.app
```

**第一次用签名版时**，App 启动会要求重装 helper（`helperVersion` 从 2 提到 3），
因为旧的 adhoc helper 不认带 Team ID 的客户端。允许一次管理员授权即可，旧的
`/Library/PrivilegedHelperTools/com.clashbar.helper` 会被覆盖。

## 跟上游同步

```bash
git fetch upstream --tags
git rebase --onto v0.4.0 v0.3.6 patched   # 旧基线 -> 新 tag
```

或者用封装好的脚本：

```bash
./Scripts/sync-upstream.sh v0.4.0
```

8 个 commit 各自独立，冲突通常只出现在被上游同时改过的文件上，逐个
`git status` 处理即可；实在难解时可以 `git rebase --skip` 掉某一项，功能会退化但
不会阻塞发布。

## 本机构建

需要**完整 Xcode**（`actool` 用来编译 asset catalog，只有 Command Line Tools 会失败）：

```bash
APP_VERSION=0.3.6 BUILD_NUMBER=1 TARGET_ARCH=arm64 ./Scripts/build.sh app
```

## 验证签名

```bash
codesign -dv --verbose=4 dist/ClashBar.app 2>&1 | grep -E 'Authority|TeamIdentifier'
codesign -d -r- dist/ClashBar.app/Contents/Library/HelperTools/com.clashbar.helper
strings dist/ClashBar.app/Contents/Library/HelperTools/com.clashbar.helper | grep 'anchor apple generic'
```
