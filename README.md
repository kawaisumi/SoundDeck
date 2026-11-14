# SoundDeck

macOS 選單列音訊管理工具：系統等化器、依 App 混音、輸出裝置管理。
功能定位類似 eqMac / SoundSource，僅供個人使用。

> 本文件是開發藍圖。每完成一個里程碑就回來更新「里程碑」的勾選狀態，
> 設計有變動時直接改這份文件，讓它永遠反映現況。

---

## 1. 目標功能

### 核心（必做）

| # | 功能 | 說明 |
|---|------|------|
| 1 | **等化器** | 對系統所有輸出聲音做頻率調整。**參數式 EQ**：每個頻段可設定類型、中心頻率、增益、Q 值，並顯示頻率響應曲線；另有前級增益 (Preamp)。詳見 §2.4 |
| 2 | **App 混音器** | 列出正在發聲的 App，各自有音量滑桿（0–200%）與靜音鈕，類似 Windows 音量混音器 |
| 3 | **輸出裝置管理** | 列出所有輸出裝置，一鍵切換系統輸出；調整裝置主音量（裝置不支援硬體音量時自動改用軟體音量，見 §2.6） |

### 建議一併做（P1，與核心一起規劃）

| 功能 | 為什麼需要 |
|------|-----------|
| **選單列 Popover 介面** | 這類工具的使用情境是「隨手調一下」，不該是一個要切換過去的視窗 |
| **EQ 預設組** | 內建 Flat / Bass Boost / Vocal / Treble 等，並可儲存自訂組合 |
| **每個輸出裝置各自的 EQ** | 耳機與喇叭需要的 EQ 完全不同；切換裝置時自動套用對應設定，這是實際使用時最有感的功能 |
| **限幅器 (Limiter)** | EQ 增益與 App 音量超過 100% 都會造成削波爆音，輸出端必須有保護 |
| **一鍵 Bypass** | 快速 A/B 比較，也方便排查「是不是這個 App 造成的問題」 |
| **設定持久化** | 依 App 的 bundle ID 記住音量；依裝置 UID 記住 EQ |
| **開機自動啟動** | 用 `SMAppService`，選單列工具的基本配備 |
| **音量電平表** | 混音器每一列顯示即時電平，一眼看出是誰在發聲 |
| **依 App 指定輸出裝置（開關功能）** | 預設關閉，所有 App 走系統預設輸出。開啟後混音器每一列多一個裝置選單，可指定該 App 走哪個裝置；未指定的 App 仍「跟隨系統預設」。詳見 §2.5 |

### 之後再評估（P2）

- **圖形式 EQ 模式**（固定 10 段的簡易介面，底層共用參數式 EQ 引擎）
- **依 App 獨立 EQ**
- **輸入裝置（麥克風）選擇與音量**
- **裝置優先順序**：接上 AirPods 時自動切換／拔除時退回指定裝置
- **全域快捷鍵**：切換裝置、Bypass、切換 EQ 預設
- **AutoEQ 耳機校正檔匯入**（AutoEQ 輸出的就是參數式 EQ 設定，引擎可直接套用）
- **左右聲道平衡**

### 不做

- 自製虛擬音訊驅動程式（見下方技術選型）
- 載入第三方 Audio Unit 外掛
- 上架 App Store、支援 macOS 14.2 以前的系統

---

## 2. 技術選型

### 2.1 音訊攔截：Core Audio Process Tap（不裝驅動）

要改變別的 App 的聲音，有兩條路：

| | 虛擬音訊驅動（eqMac、舊版 SoundSource、BlackHole） | **Core Audio Process Tap（本專案採用）** |
|---|---|---|
| 原理 | 安裝一個假的輸出裝置，把系統輸出導過去再轉送 | macOS 14.2 起的官方 API，直接攔截指定 process 的輸出 |
| 安裝 | 需要管理員權限安裝 HAL plug-in，要重啟 coreaudiod | 不需要安裝任何東西，只要使用者授權 |
| 依 App 分離 | 驅動內要自己辨識 client，實作複雜 | API 原生支援指定 process |
| 當掉時 | 系統輸出可能卡在假裝置上，變成沒聲音 | Tap 隨 process 消失，聲音自動恢復正常 |
| 系統音量鍵 | 控制的是假裝置，需要另外轉接 | 仍然直接控制真實裝置 |
| 缺點 | 維護成本高、每次系統更新都有風險 | 需要「系統音訊錄製」權限；API 較新、文件少 |

開發機是 macOS 26，Process Tap 完全可用，因此採用右邊的方案。

### 2.2 訊號流程

```
 App A ──tap(靜音原聲)──▶ 增益 A ─┐
 App B ──tap(靜音原聲)──▶ 增益 B ─┼─▶ 混合 ─▶ Preamp ─▶ 10 段 EQ ─▶ Limiter ─▶ 實體輸出裝置
 App C ──tap(靜音原聲)──▶ 增益 C ─┘
```

上圖是「一條輸出管線」。每個正在使用的輸出裝置各有一條（見 §2.5）；
未開啟依 App 指定裝置時，全系統只有一條。

1. 透過 `kAudioHardwarePropertyProcessObjectList` 取得所有音訊 process，監聽其變化。
2. 為每個 App 建立一個 `CATapDescription`（stereo mixdown，`muteBehavior = .mutedWhenTapped`），
   原本的聲音被靜音，改由我們重新播放。沒有被個別攔截的聲音（系統音效等）由一個
   「其他」tap 統一收進來（§2.6）。
3. 建立一個 **private aggregate device**：子裝置是目前的實體輸出裝置，tap list 放入所有 tap。
4. 在這個 aggregate device 上掛 IOProc：輸入端收到各 tap 的音訊，處理後寫到輸出端。
5. 輸出裝置切換、取樣率改變、App 開始／停止發聲時，重建或更新這條管線。

**Tap 的範圍一律限定在「送往這條管線的輸出裝置」的聲音**，不使用全域 tap。
全域 tap 會把別的程式送往別的裝置的聲音也抓進來；如果系統裡有其他音訊轉送工具
（虛擬裝置 → 實體喇叭，例如原版 eqMac），它轉送出來的聲音會被我們再抓一次、再送回虛擬裝置，
形成回授。M0 測試時實際發生過（見 §5）。

macOS 26 的 `CATapDescription` 新增 `bundleIDs` 與 `processRestoreEnabled`，可以直接用 bundle ID
指定要攔截的 App，並在 App 重開後自動恢復。M3 優先評估用它取代自己追蹤 PID。

### 2.3 其他選型

| 項目 | 選擇 | 理由 |
|------|------|------|
| 語言 | Swift 6 | Core Audio 的 C API 可直接呼叫 |
| UI | SwiftUI + `MenuBarExtra`（`.window` 樣式） | 選單列 Popover 的標準做法 |
| DSP | 自行實作 biquad 串接（RBJ Audio EQ Cookbook），以 Accelerate/vDSP 加速 | 可完全掌控即時執行緒的行為；十幾段 biquad 計算量很小 |
| 設定儲存 | `UserDefaults` + Codable JSON | 資料量小，不需要資料庫 |
| 介面語言 | 繁體中文（字串集中用 String Catalog 管理，之後要加英文不必改程式） | |
| 最低系統 | macOS 14.2（實際只在 macOS 26 上測試） | Process Tap 的最低需求 |
| 建置 | Swift Package Manager ＋ 打包腳本產生 `.app`；用 Xcode 直接開啟 `Package.swift` 來除錯與跑 Instruments | 專案結構保持純文字、容易維護，同時仍可使用 Xcode 的工具 |

### 2.4 參數式 EQ 規格

- **頻段數**：預設 5 段，可增減，上限 16 段
- **每段參數**
  - 類型：Peak（鐘形）、Low Shelf、High Shelf、High-pass、Low-pass、Notch
  - 頻率：20 Hz – 20 kHz（對數刻度）
  - 增益：±18 dB（High-pass / Low-pass / Notch 無增益）
  - Q 值：0.1 – 18
  - 個別啟用／停用
- **Preamp**：±18 dB，另提供「自動補償」選項（依曲線最高點自動降低，避免削波）
- **介面**：頻率響應曲線圖，每段是一個可拖曳的控制點（左右＝頻率、上下＝增益、滾輪或捏合＝Q），
  下方列出各段的精確數值可手動輸入
- **曲線計算**：由 biquad 係數直接算出總頻率響應，畫面顯示的就是實際套用的結果
- **參數變動**：即時執行緒端對係數做平滑過渡，拖曳時不產生雜音

### 2.5 依 App 指定輸出裝置

設定中有一個總開關「**依 App 指定輸出裝置**」，預設關閉。

| 開關狀態 | 行為 |
|---|---|
| 關閉 | 所有 App 都走系統預設輸出裝置。混音器只顯示音量與靜音 |
| 開啟 | 混音器每一列多一個裝置選單，預設值為「跟隨系統預設」；可改選特定裝置 |

規則：

- 已記住的指定關係在開關關閉時**保留但不生效**，再次開啟時恢復。
- 被指定的裝置不存在（例如耳機拔掉）時，該 App 暫時退回系統預設；裝置回來後自動恢復。
- 「跟隨系統預設」的 App 在切換系統輸出時會一起移動；已指定裝置的 App 不受影響。

架構上的做法：以**輸出裝置為單位**建立管線。每個「有 App 正在使用」的輸出裝置各有一個
aggregate device 與一條處理鏈（增益 → 混合 → EQ → Limiter），裡面只包含指定到該裝置的 App 的 tap。
開關關閉時就是只有一條管線的特例，因此**從 M0 起管線就以「可以有多條」的方式設計**，
之後開啟此功能不需要重寫。這也讓「每個裝置各自的 EQ」自然成立——EQ 本來就屬於管線。

### 2.6 管線共通規則

**聲道**
- 管線內部一律處理 2 聲道立體聲。
- 輸出寫到裝置的「偏好立體聲聲道」（`kAudioDevicePropertyPreferredChannelsForStereo`，多數裝置是 1、2，
  但錄音介面可能不是），其餘聲道填靜音；單聲道裝置左右寫同一個聲道。存取聲道前一律檢查邊界。
- 已知限制：5.1 / 7.1 內容會被降混成立體聲，接多聲道劇院系統時會失去環繞效果。

**主音量**
- 裝置支援硬體音量時控制硬體；不支援時（HDMI / DisplayPort 螢幕、部分 USB DAC）
  改用管線末端的數位增益，UI 上是同一條滑桿。
- 軟體音量的值依裝置 UID 記住。

**Limiter**
- 峰值限幅器：門檻 −1 dBFS、極短 attack（搭配約 1–2 ms 的 lookahead）、平滑 release。
- 最後再接一級只在超過門檻時才作用的軟削波當保險。
- 不使用全頻段的 `tanh` 飽和：它在正常音量下也會改變波形、產生失真，不適合放在常駐路徑上。
- 禁止單純的硬削波當成 Limiter。

**回授保護**
- 即時執行緒偵測到輸入峰值超過 +12 dBFS 或出現 NaN 時，立刻改輸出靜音並鎖住；
  引擎隨後拆除管線、停用處理，並在 UI 顯示原因。

**哪些聲音出現在混音器**
- 能歸屬到一般使用者 App（`NSRunningApplication` 的 activation policy 為 regular）的才獨立成一列，
  helper process 歸併到主 App。
- 不用「bundle ID 是否為 `com.apple.*`」來判斷：Safari 的聲音來自 `com.apple.WebKit.GPU`，
  Music、Podcasts、FaceTime 也都是 `com.apple.*`，照 bundle ID 排除會誤殺。
- 其餘無法歸屬的（通知音效、Siri、系統 daemon）合併成一列「**系統音效與其他**」，由一個
  「排除已個別攔截的 App」的 tap 收進來。這樣 EQ 仍然作用在所有聲音上，混音器也不會雜亂。

**App 何時從混音器消失**
- 停止發聲後保留 30 秒，以灰色顯示；期間 tap 保持不拆，恢復播放時不需要重建。
- 音量、靜音或指定裝置被調整過（不是預設值）的 App，只要還在執行就一直顯示。
- App 結束時立即移除。

**動態增減 tap**
- 優先嘗試在 IOProc 不停止的情況下修改 `kAudioAggregateDevicePropertyTapList`。
- 若系統不允許熱插拔而必須重建，對現有聲音做 5–10 ms 的淡出／淡入。
- 新加入的 App 本身從靜音淡入，避免第一個緩衝區出現爆音。

**休眠與喚醒**
- `NSWorkspace.willSleepNotification`：主動停止 IOProc 並拆除管線。
- `didWakeNotification`：延遲約 1 秒後重建；失敗時以遞增間隔重試數次，因為 USB 與藍牙裝置
  重新出現的時間不固定。裝置清單變化的通知也會觸發重建。

**UI**
- 電平表：即時執行緒只寫入 atomic 峰值；只有 Popover 開著時 UI 才定時讀取，收起來時完全不輪詢。
- EQ 控制點：按住 `Shift` 拖曳進入微調模式（靈敏度降為 1/5）；雙擊控制點把該段增益歸零；
  `Option` 加雙擊重設整段。
- EQ 編輯器可以「釘選」成獨立視窗：Popover 點到外面就會收合，不適合長時間調整與輸入數值。

---

## 3. 專案結構（規劃）

```
eqMac/
├── README.md
├── Package.swift
├── Sources/
│   ├── AudioCore/                 # 不依賴 UI 的音訊核心（可單元測試）
│   │   ├── HAL/                   # Core Audio 屬性存取的薄包裝
│   │   ├── Devices/               # 裝置列舉、切換、音量、屬性監聽
│   │   ├── Processes/             # 音訊 process 列舉、helper 歸併到主 App
│   │   ├── Tap/                   # Process Tap、aggregate device、IOProc 生命週期
│   │   ├── DSP/                   # Biquad、參數式 EQ、頻率響應計算、Limiter、增益平滑、電平量測
│   │   ├── Pipeline/              # OutputPipeline：單一輸出裝置的 tap 集合與處理鏈
│   │   └── Engine/                # AudioEngine：管理多條管線、App→裝置的路由，對外介面
│   ├── Persistence/               # 設定模型與儲存
│   └── App/                       # SwiftUI：MenuBarExtra、EQ / Mixer / Devices 畫面
├── Tests/
│   └── AudioCoreTests/            # DSP 係數、頻率響應、設定序列化
├── Resources/
│   └── Info.plist                 # LSUIElement、NSAudioCaptureUsageDescription
└── Scripts/
    └── bundle.sh                  # swift build → 組裝 .app → 簽章
```

---

## 4. 里程碑

每個里程碑結束時都要有「可以實際聽到／看到」的成果。

- [x] **M0 — 概念驗證**
  - SPM 專案骨架、打包成 `.app`
  - 建立 tap 與 aggregate device、IOProc 啟動、預設輸出裝置改變時重建
  - 回授保護、選單列的最小介面（開關、裝置資訊、輸入電平）
  - 實測：內建揚聲器與 HDMI 投影機外接喇叭都能正常出聲（48 kHz / 512 frames，約 11 ms 緩衝）
  - 未涵蓋：回授保護沒有被實際觸發過；藍牙與 USB 裝置、休眠喚醒尚未測試
- [ ] **M1 — 輸出裝置管理**
  - 列出裝置、切換預設輸出、調整主音量（含軟體音量備援）、監聽裝置插拔
  - 切換裝置時管線自動重建；休眠／喚醒處理
- [ ] **M2 — 等化器**
  - 參數式 EQ 引擎（§2.4）＋ Preamp ＋ Limiter，參數變動平滑化（不產生雜音）
  - 頻率響應曲線圖與可拖曳控制點
  - 內建預設組、Bypass
- [ ] **M3 — App 混音器**
  - 改為每個 App 一個 tap；各自音量、靜音、電平表
  - Helper process 歸併到主 App（見 §5）
- [ ] **M4 — 依 App 指定輸出裝置**
  - 總開關、每列的裝置選單、多條管線同時運作（§2.5）
  - 裝置消失時退回系統預設、回來時恢復
- [ ] **M5 — 介面與持久化**
  - 完整的選單列 Popover（裝置 / 混音器 / EQ 三區），繁體中文介面
  - 記住 App 音量與指定裝置、每個裝置各自的 EQ、自訂預設組、開機啟動
- [ ] **M6 — P2 功能**（依實際使用感受挑選）

---

## 5. 已知難點與風險

| 問題 | 說明 | 對策 |
|------|------|------|
| **Helper process** | 瀏覽器、Electron App 的聲音實際上由 helper process 發出（如 `Google Chrome Helper`、`com.apple.WebKit.GPU`），不是主程式 | 沿著 parent PID／responsible process 往上找到主 App 再歸併；Safari 的 WebKit process 需要特別處理 |
| **即時執行緒安全** | IOProc 內不能配置記憶體、上鎖、呼叫 Swift runtime 中可能阻塞的東西，否則會爆音 | 參數用 atomic／lock-free 方式傳遞；所有 buffer 預先配置；DSP 寫成不配置記憶體的純運算 |
| **延遲** | 多一層轉送必然增加延遲，影片對嘴與遊戲會受影響 | M0 就量測；調小 buffer size；必要時提供「低延遲模式」 |
| **多 tap 的 aggregate device** | 一個 aggregate device 掛多個 tap、動態增減 tap 的行為文件很少 | M3 開頭先做小型實驗；備案是每個 App 各自一個 aggregate device |
| **App 在裝置間搬移** | 改變某 App 的指定裝置時，要把它的 tap 從一條管線移到另一條，過程中可能有短暫斷音 | 搬移時對該 App 做極短的淡出／淡入；先求不爆音 |
| **權限與簽章** | TCC 權限綁定程式簽章；ad-hoc 簽章每次重新建置都可能要重新授權 | 建立一張固定的自簽憑證專門簽這個 App |
| **取樣率／格式變化** | 不同裝置取樣率不同，切換時 EQ 係數要重算 | 管線重建時一併以新取樣率重算係數 |
| **藍牙裝置** | AirPods 連線時取樣率與延遲會變動，通話模式會切到低音質 | 監聽格式變化並重建；先求穩定再求完美 |
| **與其他音訊工具共存** | M0 測試時原版 eqMac 正在執行（預設輸出是它的虛擬裝置）。當時用全域 tap，抓到 eqMac 轉送給喇叭的聲音又送回 eqMac，音量在數秒內暴衝 | 已改為只攔截送往自己輸出裝置的聲音，並加上回授保護。即使如此，兩套 EQ 疊在一起沒有意義，使用 SoundDeck 時建議結束 eqMac 並把輸出切回實體裝置 |
| **休眠喚醒** | 喚醒後裝置重新初始化的時序不固定，aggregate device 容易無聲或取樣率錯亂 | 見 §2.6：休眠前拆除、喚醒後延遲重建並重試 |
| **不支援硬體音量的裝置** | HDMI / DP 螢幕與部分 DAC 沒有音量屬性 | 見 §2.6：自動改用軟體音量 |
| **多串流裝置** | 目前只攔截輸出裝置的第 1 個串流；少數專業介面把聲道分在多個串流上 | 遇到實際裝置再處理 |
| **受保護內容** | 部分 DRM 音訊可能無法被 tap | 無法解決，偵測到時在 UI 提示 |

---

## 6. 開發環境

- macOS 26.5.2（Apple Silicon）、Swift 6.3.3
- Xcode 27.2（已安裝）。用 Xcode 開啟 `Package.swift` 即可除錯與跑 Instruments
- Git：本資料夾已是獨立的 repo

### 建置與執行

```
./Scripts/bundle.sh        # 建置並產生 build/SoundDeck.app（加 debug 參數可建置除錯版）
open build/SoundDeck.app
```

首次執行會跳出「系統音訊錄製」的授權視窗，必須允許；在按下允許之前管線不會啟動。
之後可在「系統設定 → 隱私權與安全性 → 螢幕與系統音訊錄製」管理。

### 簽章與權限

權限綁定程式簽章。目前用 ad-hoc 簽章，**每次重新建置後系統都會再問一次權限**。
要避免這件事，在「鑰匙圈存取 → 憑證輔助程式 → 製作憑證」建立一張名為 `SoundDeck Dev`、
類型為「程式碼簽章」的自簽憑證；`bundle.sh` 偵測到它就會自動改用。

### 診斷記錄

```
open build/SoundDeck.app --args --log-stats
/usr/bin/log stream --predicate 'subsystem == "local.sounddeck.app"' --style compact
```

`--log-stats` 會每 2 秒記錄一次 callback 次數與輸入峰值。

---

## 7. 待決定事項

- [x] App 正式名稱 → SoundDeck
- [x] 安裝 Xcode → 已安裝
- [x] EQ 形式 → 先做參數式，圖形式之後再評估
- [x] 介面語言 → 先做繁體中文
- [x] 依 App 指定輸出裝置 → 要做，做成開關功能（§2.5）
