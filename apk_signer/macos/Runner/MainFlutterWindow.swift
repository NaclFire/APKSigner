import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerDesktopChannel(viewController: flutterViewController)

    super.awakeFromNib()
  }
}

/// 注册 "apk_signer/desktop" 通道（macOS 只需 getAssetsDir；
/// 进程启动走 dart:io Process，无控制台窗口问题）。
private func registerDesktopChannel(viewController: FlutterViewController) {
  let registrar = viewController.registrar(forPlugin: "ApkSignerDesktop")!
  let channel = FlutterMethodChannel(
    name: "apk_signer/desktop", binaryMessenger: registrar.messenger())
  channel.setMethodCallHandler { call, result in
    switch call.method {
    case "getAssetsDir":
      if let dir = resolveAssetsDir() {
        result(dir)
      } else {
        result(FlutterError(code: "no-assets",
                            message: "flutter_assets directory not found",
                            details: nil))
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// 定位打包进来的签名运行环境目录（signer，内含 apksigner.jar 与 jre/）。
///
/// 首选 Contents/Resources/signer：由 Xcode "Copy Signer Runtime" 构建阶段
/// 从项目 assets/signer-macos 整体拷贝（pubspec 资产管道会丢弃 .dylib）。
/// 其余为兜底路径，便于不同打包布局。
private func resolveAssetsDir() -> String? {
  let fm = FileManager.default

  // 1. Contents/Resources/signer（正式布局）
  if let res = Bundle.main.resourcePath {
    let p = res + "/signer"
    if fm.fileExists(atPath: p) { return p }
  }

  // 2. flutter_assets/assets（旧布局兜底）
  if let fw = Bundle.main.path(forResource: "FlutterMacOS", ofType: "framework"),
     let res = Bundle(path: fw)?.resourcePath {
    let p = res + "/flutter_assets/assets/signer"
    if fm.fileExists(atPath: p) { return p }
  }

  // 3. 可执行文件相对路径
  if let exec = Bundle.main.executablePath {
    let dir = (exec as NSString).deletingLastPathComponent
    for base in [dir, dir + "/..", dir + "/../.."] {
      for sub in ["signer", "data/flutter_assets/assets/signer"] {
        let p = (base + "/" + sub as NSString).standardizingPath
        if fm.fileExists(atPath: p) { return p }
      }
    }
  }

  return nil
}
