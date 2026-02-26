#!/usr/bin/env dart

import 'dart:io';
import 'dart:ffi';
import 'dart:async';
import 'dart:convert';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;

/// 命令行版本的微信密钥提取工具
/// 无需Flutter界面，直接通过命令行参数运行

// DLL导出函数类型定义
typedef InitializeHookNative = Bool Function(Uint32 targetPid);
typedef InitializeHookDart = bool Function(int targetPid);

typedef PollKeyDataNative = Bool Function(Pointer<Utf8> keyBuffer, Int32 bufferSize);
typedef PollKeyDataDart = bool Function(Pointer<Utf8> keyBuffer, int bufferSize);

typedef GetStatusMessageNative = Bool Function(
  Pointer<Utf8> statusBuffer,
  Int32 bufferSize,
  Pointer<Int32> outLevel,
);
typedef GetStatusMessageDart = bool Function(
  Pointer<Utf8> statusBuffer,
  int bufferSize,
  Pointer<Int32> outLevel,
);

typedef CleanupHookNative = Bool Function();
typedef CleanupHookDart = bool Function();

typedef GetLastErrorMsgNative = Pointer<Utf8> Function();
typedef GetLastErrorMsgDart = Pointer<Utf8> Function();

/// CLI参数配置
class CliConfig {
  final int? targetPid;
  final String dllPath;
  final Duration pollInterval;
  final Duration maxDuration;
  final bool verbose;
  final String? outputFile;

  CliConfig({
    this.targetPid,
    required this.dllPath,
    this.pollInterval = const Duration(milliseconds: 100),
    this.maxDuration = const Duration(minutes: 5),
    this.verbose = false,
    this.outputFile,
  });
}

/// 日志级别
enum LogLevel { info, success, error, debug }

/// 简单的日志系统
class Logger {
  static bool _verbose = false;

  static void init({bool verbose = false}) {
    _verbose = verbose;
  }

  static void log(String message, LogLevel level) {
    final timestamp = DateTime.now().toString().substring(11, 19);
    final levelStr = level.name.toUpperCase().padRight(7);
    final color = _getColorCode(level);
    
    print('$color[$timestamp] $levelStr $message\x1B[0m');
  }

  static void info(String message) => log(message, LogLevel.info);
  static void success(String message) => log(message, LogLevel.success);
  static void error(String message) => log(message, LogLevel.error);
  static void debug(String message) {
    if (_verbose) log(message, LogLevel.debug);
  }

  static String _getColorCode(LogLevel level) {
    switch (level) {
      case LogLevel.info: return '\x1B[36m'; // 青色
      case LogLevel.success: return '\x1B[32m'; // 绿色
      case LogLevel.error: return '\x1B[31m'; // 红色
      case LogLevel.debug: return '\x1B[35m'; // 紫色
    }
  }
}

/// 微信密钥提取器
class WeChatKeyExtractor {
  DynamicLibrary? _dll;
  InitializeHookDart? _initializeHook;
  PollKeyDataDart? _pollKeyData;
  GetStatusMessageDart? _getStatusMessage;
  CleanupHookDart? _cleanupHook;
  GetLastErrorMsgDart? _getLastErrorMsg;
  
  Timer? _pollingTimer;
  final List<String> _extractedKeys = [];
  bool _isRunning = false;
  Completer<void>? _completer;

  /// 初始化DLL
  Future<bool> initialize(String dllPath) async {
    try {
      Logger.info('加载控制器DLL: $dllPath');
      
      if (!File(dllPath).existsSync()) {
        Logger.error('DLL文件不存在: $dllPath');
        return false;
      }
      
      // 加载DLL
      _dll = DynamicLibrary.open(dllPath);
      Logger.success('DLL加载成功');
      
      // 查找导出函数
      _initializeHook = _dll!.lookupFunction<InitializeHookNative, InitializeHookDart>(
        'InitializeHook',
      );
      
      _pollKeyData = _dll!.lookupFunction<PollKeyDataNative, PollKeyDataDart>(
        'PollKeyData',
      );
      
      _getStatusMessage = _dll!.lookupFunction<GetStatusMessageNative, GetStatusMessageDart>(
        'GetStatusMessage',
      );
      
      _cleanupHook = _dll!.lookupFunction<CleanupHookNative, CleanupHookDart>(
        'CleanupHook',
      );
      
      _getLastErrorMsg = _dll!.lookupFunction<GetLastErrorMsgNative, GetLastErrorMsgDart>(
        'GetLastErrorMsg',
      );
      
      Logger.success('所有导出函数加载成功');
      return true;
    } catch (e) {
      Logger.error('初始化DLL失败: $e');
      return false;
    }
  }

  /// 开始提取密钥
  Future<List<String>> extractKeys(int targetPid, Duration maxDuration, Duration pollInterval) async {
    if (_dll == null || _initializeHook == null) {
      Logger.error('DLL未初始化');
      return [];
    }
    
    try {
      Logger.info('开始安装远程Hook，目标PID: $targetPid');
      
      // 初始化Hook
      final success = _initializeHook!(targetPid);
      
      if (!success) {
        final error = _getLastErrorMessage();
        Logger.error('远程Hook安装失败: $error');
        return [];
      }
      
      Logger.success('远程Hook安装成功');
      _isRunning = true;
      _completer = Completer<void>();
      
      // 启动轮询
      _startPolling(pollInterval);
      
      // 等待完成或超时
      await Future.any([
        _completer!.future,
        Future.delayed(maxDuration),
      ]);
      
      return _extractedKeys;
    } catch (e) {
      Logger.error('提取密钥异常: $e');
      return [];
    } finally {
      _stop();
    }
  }

  /// 启动轮询
  void _startPolling(Duration interval) {
    _pollingTimer?.cancel();
    _pollingTimer = Timer.periodic(interval, (_) {
      _pollData();
    });
    Logger.info('已启动轮询定时器');
  }

  /// 停止轮询
  void _stopPolling() {
    _pollingTimer?.cancel();
    _pollingTimer = null;
    Logger.info('已停止轮询定时器');
  }

  /// 轮询数据
  void _pollData() {
    if (_pollKeyData == null || _getStatusMessage == null) {
      return;
    }
    
    try {
      // 检查密钥数据
      final keyBuffer = calloc<Uint8>(65);
      try {
        if (_pollKeyData!(keyBuffer.cast<Utf8>(), 65)) {
          final keyString = _decodeUtf8String(keyBuffer, 65);
          Logger.success('提取到密钥: $keyString');
          _extractedKeys.add(keyString);
          
          // 如果已提取到密钥，可以考虑停止
          if (_extractedKeys.isNotEmpty && !_isRunning) {
            _completer?.complete();
          }
        }
      } finally {
        calloc.free(keyBuffer);
      }
      
      // 检查状态消息
      for (int i = 0; i < 5; i++) {
        final statusBuffer = calloc<Uint8>(256);
        final levelPtr = calloc<Int32>();
        
        try {
          if (_getStatusMessage!(statusBuffer.cast<Utf8>(), 256, levelPtr)) {
            final statusString = _decodeUtf8String(statusBuffer, 256);
            final level = levelPtr.value;
            
            switch (level) {
              case 0:
                Logger.debug('[DLL] $statusString');
                break;
              case 1:
                Logger.info('[DLL] $statusString');
                break;
              case 2:
                Logger.error('[DLL] $statusString');
                break;
            }
          } else {
            break;
          }
        } finally {
          calloc.free(statusBuffer);
          calloc.free(levelPtr);
        }
      }
    } catch (e) {
      Logger.error('轮询数据异常: $e');
    }
  }

  /// 获取最后一次错误信息
  String _getLastErrorMessage() {
    try {
      if (_dll == null || _getLastErrorMsg == null) {
        return '未知错误';
      }
      
      final errorPtr = _getLastErrorMsg!();
      if (errorPtr == nullptr) {
        return '无错误';
      }
      
      return _decodeUtf8String(errorPtr.cast<Uint8>(), 512);
    } catch (e) {
      return '获取错误信息失败: $e';
    }
  }

  /// 停止提取
  void _stop() {
    _isRunning = false;
    _stopPolling();
    
    if (_dll != null && _cleanupHook != null) {
      Logger.info('开始卸载Hook');
      final success = _cleanupHook!();
      
      if (success) {
        Logger.success('Hook卸载成功');
      } else {
        Logger.error('Hook卸载失败');
      }
    }
    
    _completer?.complete();
  }

  /// 清理资源
  void dispose() {
    _stop();
    _dll = null;
    _initializeHook = null;
    _pollKeyData = null;
    _getStatusMessage = null;
    _cleanupHook = null;
    _getLastErrorMsg = null;
  }

  String _decodeUtf8String(Pointer<Uint8> buffer, int maxLength) {
    if (buffer == nullptr) return '';
    final bytes = <int>[];
    for (var i = 0; i < maxLength; i++) {
      final value = buffer.elementAt(i).value;
      if (value == 0) break;
      bytes.add(value);
    }
    if (bytes.isEmpty) return '';
    return utf8.decode(bytes, allowMalformed: true);
  }
}

/// 查找微信进程PID
int? findWeChatProcess() {
  try {
    // 优先：直接查找加载了 Weixin.dll 的进程（最可靠）
    final dllProbe = Process.runSync('tasklist', ['/m', 'Weixin.dll', '/FO', 'CSV', '/NH']);
    if (dllProbe.exitCode == 0) {
      final text = dllProbe.stdout.toString().trim();
      if (text.isNotEmpty) {
        final lines = text.split('\n');
        int? pickedPid;
        String? pickedName;
        // 1) 优先选择 Weixin.exe（最常见的核心进程）
        for (final raw in lines) {
          final line = raw.trim();
          if (line.isEmpty) continue;
          final cols = line.split('","');
          if (cols.length < 2) continue;
          final name = cols[0].replaceAll('"', '').trim();
          final pidStr = cols[1].replaceAll('"', '').trim();
          if (name.toLowerCase() == 'weixin.exe') {
            final pid = int.tryParse(pidStr);
            if (pid != null) {
              pickedPid = pid;
              pickedName = name;
              break;
            }
          }
        }
        // 2) 如果没有 Weixin.exe，则取列表中的第一个（已确认加载了 Weixin.dll）
        if (pickedPid == null) {
          final first = lines.first.trim();
          final cols = first.split('","');
          if (cols.length >= 2) {
            final name = cols[0].replaceAll('"', '').trim();
            final pidStr = cols[1].replaceAll('"', '').trim();
            final pid = int.tryParse(pidStr);
            if (pid != null) {
              Logger.info('选择加载Weixin.dll的进程: $name (PID: $pid)');
              return pid;
            }
          }
        } else {
          Logger.info('选择核心进程: $pickedName (PID: $pickedPid)');
          return pickedPid;
        }
      }
    }

    // 退而求其次：直接选择 Weixin.exe（如果未能通过模块定位）
    var result = Process.runSync('tasklist', ['/FI', 'IMAGENAME eq Weixin.exe', '/FO', 'CSV', '/NH']);
    if (result.exitCode == 0) {
      final lines = result.stdout.toString().trim().split('\n');
      for (final raw in lines) {
        final line = raw.trim();
        if (line.isEmpty || !line.contains('Weixin.exe')) continue;
        final cols = line.split('","');
        if (cols.length >= 2) {
          final pidStr = cols[1].replaceAll('"', '').trim();
          final pid = int.tryParse(pidStr);
          if (pid != null) {
            Logger.info('选择进程: Weixin.exe (PID: $pid)');
            return pid;
          }
        }
      }
    }

    // 最后兜底：回退到 WeChatAppEx.exe，并选择内存占用最大的一个
    result = Process.runSync('tasklist', ['/FI', 'IMAGENAME eq WeChatAppEx.exe', '/FO', 'CSV']);
    if (result.exitCode != 0) return null;

    final lines = result.stdout.toString().trim().split('\n');
    int? bestPid;
    int bestMem = -1;
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty || !line.contains('WeChatAppEx.exe')) continue;
      final cols = line.split('","');
      if (cols.length < 5) continue;
      final pidStr = cols[1].replaceAll('"', '').trim();
      final memStr = cols[4].replaceAll('"', '').replaceAll(',', '').replaceAll(' K', '').trim();
      final pid = int.tryParse(pidStr);
      final mem = int.tryParse(memStr) ?? 0;
      if (pid != null && mem > bestMem) {
        bestMem = mem;
        bestPid = pid;
      }
    }
    return bestPid;
  } catch (e) {
    Logger.error('查找微信进程失败: $e');
    return null;
  }
}

bool _isAdministrator() {
  try {
    // 使用 fltmc 检测管理员权限（更可靠）
    final res = Process.runSync('fltmc', [], runInShell: true);
    return res.exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// 解析命令行参数
CliConfig? parseArguments(List<String> args) {
  final parser = ArgParser()
    ..addOption('pid', abbr: 'p', help: '微信进程PID（可选，会自动查找）')
    ..addOption('dll', abbr: 'd', defaultsTo: 'assets/dll/wx_key.dll', help: 'DLL文件路径')
    ..addOption('interval', abbr: 'i', defaultsTo: '100', help: '轮询间隔（毫秒）')
    ..addOption('timeout', abbr: 't', defaultsTo: '300', help: '超时时间（秒）')
    ..addOption('output', abbr: 'o', help: '输出文件路径')
    ..addFlag('verbose', abbr: 'v', help: '详细输出')
    ..addFlag('help', abbr: 'h', help: '显示帮助信息');

  try {
    final results = parser.parse(args);
    
    if (results['help']) {
      print('微信密钥提取工具 - 命令行版本\n');
      print('使用方法: dart cli_extractor.dart [选项]\n');
      print('选项:');
      print(parser.usage);
      return null;
    }
    
    final targetPid = results['pid'] != null ? int.tryParse(results['pid']) : null;
    final dllPath = results['dll'];
    final interval = Duration(milliseconds: int.parse(results['interval']));
    final timeout = Duration(seconds: int.parse(results['timeout']));
    final verbose = results['verbose'];
    final outputFile = results['output'];
    
    return CliConfig(
      targetPid: targetPid,
      dllPath: dllPath,
      pollInterval: interval,
      maxDuration: timeout,
      verbose: verbose,
      outputFile: outputFile,
    );
  } catch (e) {
    Logger.error('参数解析失败: $e');
    return null;
  }
}

/// 主函数
void main(List<String> arguments) async {
  print('微信密钥提取工具 - 命令行版本');
  print('=====================================\n');
  
  // 解析参数
  final config = parseArguments(arguments);
  if (config == null) return;
  
  // 初始化日志
  Logger.init(verbose: config.verbose);
  
  // 管理员权限检查
  // if (!_isAdministrator()) {
  //   Logger.error('非管理员权限，正在尝试以管理员权限重新启动...');
  //   try {
  //     // 获取Dart可执行文件和当前脚本的路径
  //     final executable = Platform.executable;
  //     final script = Platform.script.toFilePath(windows: true);

  //     // 组合所有参数（脚本路径和原始参数）
  //     final allArgs = [script, ...arguments];
  //     // 为PowerShell的ArgumentList准备参数，正确处理引号和空格
  //     final psArgs = allArgs.map((a) => "'${a.replaceAll("'", "''")}'").join(',');

  //     // 构建用于提权的PowerShell命令
  //     final command =
  //         'Start-Process -FilePath "$executable" -ArgumentList @($psArgs) -Verb RunAs';

  //     // 执行提权命令。这将打开一个UAC提示。
  //     // 用户同意后，将启动一个新的管理员权限的进程。
  //     Process.runSync('powershell', ['-NoProfile', '-Command', command]);
  //   } catch (e) {
  //     Logger.error('自动提权失败: $e');
  //     Logger.error('请右键单击终端或脚本，选择“以管理员身份运行”。');
  //   }
  //   // 退出当前的非管理员进程。
  //   return;
  // }
  
  // 查找微信进程
  final targetPid = config.targetPid ?? findWeChatProcess();
  if (targetPid == null) {
    Logger.error('未找到微信进程，请确保微信已启动');
    exit(1);
  }
  
  Logger.info('目标微信进程PID: $targetPid');
  
  // 创建提取器
  final extractor = WeChatKeyExtractor();
  
  try {
    // 初始化DLL
    final initSuccess = await extractor.initialize(config.dllPath);
    if (!initSuccess) {
      exit(1);
    }
    
    // 开始提取
    Logger.info('开始提取密钥（最大等待时间: ${config.maxDuration.inSeconds}秒）...');
    final keys = await extractor.extractKeys(
      targetPid,
      config.maxDuration,
      config.pollInterval,
    );
    
    // 输出结果
    if (keys.isEmpty) {
      Logger.error('未提取到任何密钥');
      exit(1);
    } else {
      Logger.success('成功提取到 ${keys.length} 个密钥:');
      for (final key in keys) {
        print('  - $key');
      }
      
      // 保存到文件
      if (config.outputFile != null) {
        final file = File(config.outputFile!);
        await file.writeAsString(keys.join('\n'));
        Logger.success('密钥已保存到: ${config.outputFile}');
      }
    }
    
  } finally {
    extractor.dispose();
  }
}

/// 简单的参数解析器（避免依赖第三方库）
class ArgParser {
  final Map<String, ArgOption> _options = {};
  
  void addOption(String name, {
    String? abbr,
    String? defaultsTo,
    String? help,
  }) {
    _options[name] = ArgOption(
      name: name,
      abbr: abbr,
      defaultsTo: defaultsTo,
      help: help,
    );
  }
  
  void addFlag(String name, {
    String? abbr,
    String? help,
  }) {
    _options[name] = ArgOption(
      name: name,
      abbr: abbr,
      help: help,
      isFlag: true,
    );
  }
  
  ArgResults parse(List<String> args) {
    final results = <String, dynamic>{};
    
    // 设置默认值
    for (final option in _options.values) {
      if (option.defaultsTo != null) {
        results[option.name] = option.defaultsTo;
      } else if (option.isFlag) {
        results[option.name] = false;
      }
    }
    
    // 解析参数
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      
      if (arg.startsWith('--')) {
        final name = arg.substring(2);
        final option = _options[name];
        
        if (option == null) {
          throw ArgumentError('未知选项: $arg');
        }
        
        if (option.isFlag) {
          results[name] = true;
        } else {
          if (i + 1 >= args.length) {
            throw ArgumentError('选项 $arg 需要参数');
          }
          results[name] = args[++i];
        }
      } else if (arg.startsWith('-')) {
        final abbr = arg.substring(1);
        final option = _options.values.firstWhere(
          (opt) => opt.abbr == abbr,
          orElse: () => throw ArgumentError('未知选项: $arg'),
        );
        
        if (option.isFlag) {
          results[option.name] = true;
        } else {
          if (i + 1 >= args.length) {
            throw ArgumentError('选项 $arg 需要参数');
          }
          results[option.name] = args[++i];
        }
      }
    }
    
    return ArgResults(results);
  }
  
  String get usage {
    final buffer = StringBuffer();
    for (final option in _options.values) {
      final abbr = option.abbr != null ? '-${option.abbr}, ' : '    ';
      buffer.write('$abbr--${option.name.padRight(12)}');
      if (option.help != null) {
        buffer.write(' ${option.help}');
      }
      if (option.defaultsTo != null) {
        buffer.write(' (默认: ${option.defaultsTo})');
      }
      buffer.writeln();
    }
    return buffer.toString();
  }
}

class ArgOption {
  final String name;
  final String? abbr;
  final String? defaultsTo;
  final String? help;
  final bool isFlag;

  ArgOption({
    required this.name,
    this.abbr,
    this.defaultsTo,
    this.help,
    this.isFlag = false,
  });
}

class ArgResults {
  final Map<String, dynamic> _results;

  ArgResults(this._results);

  dynamic operator [](String name) => _results[name];
}
