# 微信密钥提取工具 - 命令行版本

## 简介

这是一个无需Flutter界面的命令行工具，可以直接提取微信数据库密钥和图片解密密钥。

## 使用方法

### 基本用法

```bash
# 自动查找微信进程并提取密钥
dart bin/cli_extractor.dart

# 指定微信进程PID
dart bin/cli_extractor.dart -p 1234

# 指定DLL路径
dart bin/cli_extractor.dart -d assets/dll/wx_key.dll

# 保存结果到文件
dart bin/cli_extractor.dart -o keys.txt

# 详细输出模式
dart bin/cli_extractor.dart -v
```

### 参数说明

```
-p, --pid        微信进程PID（可选，会自动查找）
-d, --dll        DLL文件路径（默认: assets/dll/wx_key.dll）
-i, --interval   轮询间隔，毫秒（默认: 100）
-t, --timeout    超时时间，秒（默认: 300）
-o, --output     输出文件路径（可选）
-v, --verbose    详细输出模式
-h, --help       显示帮助信息
```

### 使用示例

```bash
# 快速提取（自动查找进程）
dart bin/cli_extractor.dart

# 指定进程PID，5分钟超时，保存到文件
dart bin/cli_extractor.dart -p 5678 -t 300 -o wechat_keys.txt

# 详细模式，自定义DLL路径
dart bin/cli_extractor.dart -v -d "C:\path\to\wx_key.dll"

# 快速提取，30秒超时
dart bin/cli_extractor.dart -t 30
```

## 输出格式

成功提取的密钥将以64位十六进制字符串形式输出：

```
[20:15:30] SUCCESS 提取到密钥: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
[20:15:30] SUCCESS 提取到密钥: fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210
```

## 注意事项

1. **管理员权限/自动提权**：如果当前不是管理员，工具会自动请求UAC提权（弹窗确认）。若被安全策略阻止，请手动以管理员身份运行终端。
2. **微信版本**：支持微信4.x版本（4.1.4及以上有针对性适配）。
3. **进程查找策略**：工具会优先选择“加载了 Weixin.dll 的进程”（通常是 Weixin.exe）。如自动查找失败，请手动指定PID。
4. **DLL路径**：确保DLL文件存在且路径正确。
5. **超时设置**：根据网络和环境调整超时时间。

## 获取微信PID的方法

### Windows系统
```bash
# 推荐：查找加载了 Weixin.dll 的进程（优先目标）
tasklist /m Weixin.dll

# 或者直接查找 Weixin.exe
tasklist /FI "IMAGENAME eq Weixin.exe" /FO "CSV"

# PowerShell 查看相关进程
Get-Process -Name Weixin, WeChatAppEx | Select-Object Id, ProcessName
```

### 任务管理器
1. 打开任务管理器
2. 找到 Weixin.exe（或 WeChatAppEx.exe）进程
3. 查看PID列

## 故障排除

### DLL加载失败
- 确保DLL文件存在
- 检查文件路径是否正确
- 尝试以管理员身份运行

### 找不到微信进程
- 确保微信已启动
- 手动指定进程PID
- 使用 `tasklist /m Weixin.dll` 或确认 `Weixin.exe` 是否存在

### 提取失败
- 检查微信版本是否支持
- 确保有管理员权限（自动提权被阻止时需手动以管理员运行）
- 确认选择的是加载了 Weixin.dll 的正确进程（通常为 Weixin.exe）
- 查看详细输出了解具体错误

## 技术实现

该工具基于以下技术：
- **Dart FFI**：调用原生DLL函数
- **进程注入**：通过DLL注入微信进程
- **内存扫描**：扫描微信内存获取密钥
- **Hook技术**：拦截微信的密钥获取流程

### 新增策略与使用场景
- **按模块定位进程（Weixin.dll）**：多进程架构下（如 Weixin.exe 与 WeChatAppEx.exe 共存），优先锁定加载了 Weixin.dll 的核心进程，确保版本读取与特征匹配在正确模块内进行，避免“获取微信版本失败”。
- **自动提权**：在非管理员上下文自动请求UAC提权，适用于需要远程模块枚举、内存读取等高权限操作的场景。

## 安全声明

本工具仅供技术研究和学习使用，严禁用于任何恶意或非法目的。使用本工具产生的一切后果与责任，均由使用者自行承担。
