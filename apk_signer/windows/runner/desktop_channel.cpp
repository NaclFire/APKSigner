#include "desktop_channel.h"

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_call.h>
#include <flutter/method_channel.h>
#include <flutter/method_result.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>

#include <memory>
#include <string>
#include <thread>
#include <vector>

namespace apk_signer {

namespace {

// ---------- 字符串转换工具 ----------

std::string Narrow(const std::wstring& w) {
  if (w.empty()) return {};
  int len =
      WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, nullptr, 0, nullptr, nullptr);
  if (len <= 0) return {};
  std::string s(static_cast<size_t>(len - 1), '\0');
  WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, &s[0], len, nullptr, nullptr);
  return s;
}

std::wstring Wide(const std::string& s) {
  if (s.empty()) return {};
  int len = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
  if (len <= 0) return {};
  std::wstring w(static_cast<size_t>(len - 1), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, &w[0], len);
  return w;
}

// 按 Windows 规则给单个参数加引号
std::wstring QuoteArg(const std::wstring& arg) {
  if (!arg.empty() && arg.find_first_of(L" \t\n\v\"'\\") == std::wstring::npos) {
    return arg;
  }
  std::wstring out(L"\"");
  for (size_t i = 0; i < arg.size(); ++i) {
    if (arg[i] == L'\\') {
      // 只数反斜杠、不移动 i（for 的 ++i 会把 i 正好停在反斜杠串之后）。
      // 若在循环里 ++i，会把紧跟其后的普通字符（如路径 E:\apsig 的 'a'）吞掉。
      size_t backslashes = 0;
      size_t j = i;
      while (j < arg.size() && arg[j] == L'\\') {
        ++j;
        ++backslashes;
      }
      out.append(backslashes * 2, L'\\');
      if (j < arg.size() && arg[j] == L'"') out.push_back(L'\\');
      i = j - 1;
    } else if (arg[i] == L'"') {
      out.push_back(L'\\');
      out.push_back(L'"');
    } else {
      out.push_back(arg[i]);
    }
  }
  out.push_back(L'"');
  return out;
}

// 阻塞读取管道到 EOF
void ReadPipeTo(std::string* out, HANDLE pipe) {
  char buf[4096];
  DWORD n = 0;
  while (ReadFile(pipe, buf, sizeof(buf), &n, nullptr) && n > 0) {
    out->append(buf, n);
  }
}

// 判断字节序列是否为合法 UTF-8。
bool IsValidUtf8(const std::string& s) {
  for (size_t i = 0; i < s.size();) {
    unsigned char c = static_cast<unsigned char>(s[i]);
    size_t need = 0;
    if (c < 0x80) {
    } else if (c >= 0xC2 && c <= 0xDF) {
      need = 1;
    } else if (c >= 0xE0 && c <= 0xEF) {
      need = 2;
    } else if (c >= 0xF0 && c <= 0xF4) {
      need = 3;
    } else {
      return false;  // 0x80-0xC1、0xF5-0xFF 均非法
    }
    if (i + need + 1 > s.size()) return false;
    for (size_t k = 1; k <= need; ++k) {
      if ((static_cast<unsigned char>(s[i + k]) & 0xC0) != 0x80) return false;
    }
    i += need + 1;
  }
  return true;
}

// 管道原始字节 → UTF-8 字符串。
// 中文 Windows 上 JDK 17 的 file.encoding 跟随系统 ANSI 代码页（GBK），
// keytool 输出的中文别名/DN 是 GBK 字节，直接送进 MethodChannel 会让
// Dart 端 UTF-8 解码抛 FormatException。这里：已是合法 UTF-8 则原样保留；
// 否则按 CP_ACP（中文系统即 GBK）严格转码；仍不行则非严格解码（不可映射
// 字节变 '?'），保证任何输出都不会再炸通道。
std::string ToUtf8Text(const std::string& raw) {
  if (IsValidUtf8(raw)) return raw;
  int wlen = MultiByteToWideChar(CP_ACP, MB_ERR_INVALID_CHARS,
                                 raw.c_str(), -1, nullptr, 0);
  if (wlen > 1) {
    std::wstring w(static_cast<size_t>(wlen - 1), L'\0');
    if (MultiByteToWideChar(CP_ACP, MB_ERR_INVALID_CHARS, raw.c_str(), -1,
                            &w[0], wlen) > 0) {
      return Narrow(w);
    }
  }
  wlen = MultiByteToWideChar(CP_ACP, 0, raw.c_str(), -1, nullptr, 0);
  if (wlen > 1) {
    std::wstring w(static_cast<size_t>(wlen - 1), L'\0');
    MultiByteToWideChar(CP_ACP, 0, raw.c_str(), -1, &w[0], wlen);
    return Narrow(w);
  }
  std::string out;
  out.reserve(raw.size());
  for (char ch : raw) {
    out.push_back(static_cast<unsigned char>(ch) < 0x80 ? ch : '?');
  }
  return out;
}

std::string AssetsDir() {
  wchar_t exePath[MAX_PATH] = {};
  ::GetModuleFileNameW(nullptr, exePath, MAX_PATH);
  std::wstring exeDir(exePath);
  size_t slash = exeDir.find_last_of(L"\\/");
  if (slash != std::wstring::npos) exeDir = exeDir.substr(0, slash);
  // 布局：<exe_dir>\signer（由 CMake POST_BUILD 从项目 assets\signer 整体拷贝，
  // 内含 apksigner.jar 与 jre\；pubspec 资产管道会丢弃 .exe/.dll，不可用）
  return Narrow(exeDir + L"\\signer");
}

using MethodCall = flutter::MethodCall<flutter::EncodableValue>;
using MethodResult = flutter::MethodResult<flutter::EncodableValue>;

class DesktopChannel : public flutter::MethodChannel<flutter::EncodableValue> {
 public:
  explicit DesktopChannel(flutter::BinaryMessenger* messenger)
      : MethodChannel(messenger, "apk_signer/desktop",
                      &flutter::StandardMethodCodec::GetInstance()) {
    SetMethodCallHandler(
        [this](const MethodCall& call,
               std::unique_ptr<MethodResult> reply) {
          Handle(call, std::move(reply));
        });
  }

  void Handle(const MethodCall& call, std::unique_ptr<MethodResult> reply) {
    if (call.method_name() == "getAssetsDir") {
      reply->Success(flutter::EncodableValue(AssetsDir()));
    } else if (call.method_name() == "runHidden") {
      RunHidden(call.arguments(), std::move(reply));
    } else {
      reply->NotImplemented();
    }
  }

 private:
  static void RunHidden(const flutter::EncodableValue* args,
                        std::unique_ptr<MethodResult> reply) {
    if (!args) {
      reply->Error("missing-args", "runHidden: no arguments");
      return;
    }
    const auto* map = std::get_if<flutter::EncodableMap>(args);
    if (!map) {
      reply->Error("bad-args", "runHidden: arguments must be a map");
      return;
    }
    auto itCmd = map->find(flutter::EncodableValue("command"));
    if (itCmd == map->end()) {
      reply->Error("bad-args", "runHidden: missing command");
      return;
    }
    const auto* cmd = std::get_if<std::string>(&itCmd->second);
    if (!cmd) {
      reply->Error("bad-args", "runHidden: command must be string");
      return;
    }
    std::wstring command = Wide(*cmd);

    std::vector<std::wstring> argList;
    auto itArgs = map->find(flutter::EncodableValue("args"));
    if (itArgs != map->end()) {
      const auto* list = std::get_if<flutter::EncodableList>(&itArgs->second);
      if (list) {
        for (const auto& v : *list) {
          const auto* s = std::get_if<std::string>(&v);
          if (s) argList.push_back(Wide(*s));
        }
      }
    }

    // 环境变量覆盖（父进程临时设置，子进程继承，结束后还原）
    std::vector<std::pair<std::wstring, std::wstring>> envOverrides;
    auto itEnv = map->find(flutter::EncodableValue("env"));
    if (itEnv != map->end()) {
      const auto* envEnc = std::get_if<flutter::EncodableMap>(&itEnv->second);
      if (envEnc) {
        for (const auto& [k, v] : *envEnc) {
          const auto* ks = std::get_if<std::string>(&k);
          const auto* vs = std::get_if<std::string>(&v);
          if (ks && vs && !ks->empty()) {
            envOverrides.emplace_back(Wide(*ks), Wide(*vs));
          }
        }
      }
    }

    // 启动 + 等待退出 + 读管道都是阻塞操作。原先在平台（UI）线程上执行，
    // java 进程运行的整个期间（JVM 启动 + 对百 MB 级 APK 签名/验证，
    // 数秒到十几秒）窗口完全冻结。移到工作线程执行；Flutter Windows 的
    // messenger 发送是线程安全的，从工作线程回传结果没问题。
    // Dart 侧所有调用都是 await 串行的，父进程环境变量不会并发冲突。
    std::thread([reply = std::move(reply),
                 command = std::move(command),
                 argList = std::move(argList),
                 envOverrides = std::move(envOverrides)]() {
      // 环境变量处理：本机实测 CreateProcessW 对任意自定义 lpEnvironment 块
      // 一律返回 87（哪怕手工构造的单变量块，cmd.exe 同样失败——疑似安全产品
      // 拦截）。因此改为：在父进程临时 SetEnvironmentVariableW 设置覆盖变量，
      // 子进程走环境继承（lpEnvironment=NULL），结束后还原。
      struct EnvSave {
        std::wstring name;
        std::wstring oldValue;
        bool hadOld;
      };
      std::vector<EnvSave> envSaves;
      for (const auto& [name, value] : envOverrides) {
        EnvSave s;
        s.name = name;
        DWORD oldLen = ::GetEnvironmentVariableW(name.c_str(), nullptr, 0);
        s.hadOld = oldLen > 1;
        if (s.hadOld) {
          s.oldValue.resize(oldLen - 1);
          ::GetEnvironmentVariableW(name.c_str(), &s.oldValue[0], oldLen);
        }
        ::SetEnvironmentVariableW(name.c_str(), value.c_str());
        envSaves.push_back(std::move(s));
      }
      auto restoreEnv = [&envSaves]() {
        for (auto it = envSaves.rbegin(); it != envSaves.rend(); ++it) {
          if (it->hadOld) {
            ::SetEnvironmentVariableW(it->name.c_str(), it->oldValue.c_str());
          } else {
            ::SetEnvironmentVariableW(it->name.c_str(), nullptr);
          }
        }
      };

      std::wstring commandLine = QuoteArg(command);
      for (const auto& a : argList) commandLine += L' ' + QuoteArg(a);

      STARTUPINFOW si = {};
      si.cb = sizeof(si);
      HANDLE outPipeRead = nullptr, outPipeWrite = nullptr;
      HANDLE errPipeRead = nullptr, errPipeWrite = nullptr;
      if (!CreatePipe(&outPipeRead, &outPipeWrite, nullptr, 0) ||
          !CreatePipe(&errPipeRead, &errPipeWrite, nullptr, 0)) {
        restoreEnv();
        reply->Error("pipe-fail", "failed to create pipes");
        return;
      }
      SetHandleInformation(outPipeWrite, HANDLE_FLAG_INHERIT, 1);
      SetHandleInformation(errPipeWrite, HANDLE_FLAG_INHERIT, 1);
      si.hStdOutput = outPipeWrite;
      si.hStdError = errPipeWrite;
      si.dwFlags |= STARTF_USESTDHANDLES;

      PROCESS_INFORMATION pi = {};
      BOOL ok = CreateProcessW(nullptr,
                               const_cast<wchar_t*>(commandLine.c_str()),
                               nullptr, nullptr, TRUE,
                               CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP,
                               nullptr,  // 环境继承父进程（覆盖变量已临时设好）
                               nullptr,
                               &si, &pi);
      CloseHandle(outPipeWrite);
      CloseHandle(errPipeWrite);
      if (!ok) {
        restoreEnv();
        CloseHandle(outPipeRead);
        CloseHandle(errPipeRead);
        reply->Error("spawn-fail",
                     "failed to start process: " + std::to_string(::GetLastError()));
        return;
      }

      std::string stdoutBuf, stderrBuf;
      std::thread tOut([&] { ReadPipeTo(&stdoutBuf, outPipeRead); });
      std::thread tErr([&] { ReadPipeTo(&stderrBuf, errPipeRead); });
      ::WaitForSingleObject(pi.hProcess, INFINITE);
      DWORD exitCode = 0;
      ::GetExitCodeProcess(pi.hProcess, &exitCode);
      tOut.join();
      tErr.join();
      CloseHandle(outPipeRead);
      CloseHandle(errPipeRead);
      CloseHandle(pi.hProcess);
      CloseHandle(pi.hThread);
      restoreEnv();

      flutter::EncodableMap result;
      result[flutter::EncodableValue("exitCode")] =
          flutter::EncodableValue(static_cast<int>(exitCode));
      result[flutter::EncodableValue("stdout")] =
          flutter::EncodableValue(ToUtf8Text(stdoutBuf));
      result[flutter::EncodableValue("stderr")] =
          flutter::EncodableValue(ToUtf8Text(stderrBuf));
      reply->Success(flutter::EncodableValue(std::move(result)));
    }).detach();
  }
};

}  // namespace

void RegisterDesktopChannel(flutter::FlutterEngine* engine) {
  static std::unique_ptr<DesktopChannel> channel;
  if (channel || !engine) return;
  channel = std::make_unique<DesktopChannel>(engine->messenger());
}

}  // namespace apk_signer
