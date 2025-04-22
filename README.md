# macOS 앱에 PythonKit + pip + pyatv 번들링 가이드

## 1. 개요
이 문서는 Beeware의 **Python‑Apple‑support**를 이용해 macOS 앱에 Python 런타임(embedded framework), 표준 라이브러리, `pip` 및 `pyatv` 같은 패키지를 포함하고, Swift → PythonKit 인터페이스를 통해 Python 코드를 호출하는 과정을 한 곳에 정리한 README입니다.

---

## 2. 사전 준비
- **Xcode 14+**, **Swift 5.7+**  
- Swift Package: `PythonKit`  
  ```swift
  // Xcode 메뉴: File → Swift Packages → Add Package Dependency
  https://github.com/pvieito/PythonKit.git
  ```

---

## 3. Python‑Apple‑support 획득 및 빌드
1. 소스 클론 & 빌드
   ```bash
   git clone https://github.com/beeware/Python-Apple-support.git
   cd Python-Apple-support
   make macOS          # macOS용 XCFramework 생성
   ```
2. 또는 GitHub Releases에서 ZIP 다운로드 & 해제

빌드가 완료되면 `dist/` 폴더에 `Python.xcframework` (및 VERSIONS 파일)가 생성됩니다.

---

## 4. Xcode 프로젝트에 임베드
1. **Python.xcframework** 를 프로젝트 Navigator의 **Frameworks** 그룹에 드래그&드롭  
2. 타겟 → **General** → **Frameworks, Libraries, and Embedded Content** →  
   `Python.xcframework` → **Embed & Sign** 설정  

빌드 후 `.app/Contents/Frameworks/Python.framework` 내부에  
- `Python` (libpython3.x.dylib)  
- `Headers/`  
- `lib/python3.x/` (표준 라이브러리 .py/.so)  
- `Resources/`, `_CodeSignature/`  
등이 모두 포함됩니다.

---

## 5. Swift → Python 초기화 예제
```swift
import Cocoa
import PythonKit    // SwiftPM으로 추가한 패키지

@main
class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ _: Notification) {
    // 1) 번들 내 Python.framework Versions 디렉토리
    let verURL = Bundle.main.privateFrameworksURL!
                .appendingPathComponent("Python.framework")
                .appendingPathComponent("Versions/3.12")
    setenv("PYTHONHOME", verURL.path, 1)

    // 2) (선택) 표준 라이브러리 경로
    let stdlib = verURL.appendingPathComponent("lib/python3.12")
    setenv("PYTHONPATH", stdlib.path, 1)

    // 3) 파이썬 인터프리터 초기화
    Py_Initialize()

    // 4) (선택) libpython 경로 지정
    let libp = verURL.appendingPathComponent("Python")  // libpython3.12.dylib
    PythonLibrary.useLibrary(at: libp)

    // 예: PythonKit으로 sys 정보 출력
    let sys = Python.import("sys")
    print("Python version:", sys.version_info)
  }
}
```

---

## 6. `pip` & 추가 패키지(`pyatv`) 번들링
macOS slice에는 자체 실행기가 없으므로, 호스트 Python3를 사용해 `site‑packages`에 설치합니다:

```bash
# 1) unpack 위치로 이동
cd ~/Downloads/Python-3.12-macOS-support.b7/Python.xcframework

# 2) 사용 slice 선택
cd macos-arm64_x86_64/Python.framework/Versions/3.12

# 3) site‑packages 폴더 생성
mkdir -p lib/python3.12/site-packages

# 4) 호스트 Python3로 pip, setuptools, wheel, pyatv 설치
python3 -m pip install --upgrade pip setuptools wheel pyatv     --target "$(pwd)/lib/python3.12/site-packages"
```

설치 후 앱 번들 안에 다음 구조가 생성되었는지 확인하세요:
```
YourApp.app/Contents/Frameworks/Python.framework/Versions/3.12/
 └─ lib/python3.12/site-packages/
     ├─ pip/
     ├─ setuptools/
     ├─ wheel/
     └─ pyatv/
```

---

## 7. 런타임에 `pip` 호출하기
앱 실행 중에 외부 패키지를 설치하거나 관리하고 싶다면, 번들 내 Python 실행기를 직접 호출할 수 있습니다:

```swift
let pyExec = Bundle.main.privateFrameworksURL!
  .appendingPathComponent("Python.framework/Versions/3.12/Python").path

let task = Process()
task.executableURL = URL(fileURLWithPath: pyExec)
task.arguments = ["-m", "pip", "install", "requests"]
try! task.run()
task.waitUntilExit()
```

---

## 8. Troubleshooting
- **Permission denied**  
  - 전역 경로(`/opt/homebrew/...`)에 쓰려다 실패 → `--target` 옵션으로 번들 내부에 설치하세요.
- **exec format error**  
  - 잘못된 아키텍처(slice) 디렉토리에서 실행 시도 → `uname -m` 결과에 맞춘 slice (`macos-arm64` 또는 `macos-x86_64`) 로 들어가세요.
- **Dependency conflict**  
  - 예: TensorFlow가 요구하는 `protobuf` 버전과 충돌 시 →  
    ```bash
    python3 -m pip install "protobuf<5.0.0,>=3.20.3"        --target "$(pwd)/lib/python3.12/site-packages"
    ```

---

이 가이드를 `README.md` 파일로 저장했습니다.