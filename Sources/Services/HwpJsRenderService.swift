import Foundation

enum HwpJsRenderError: Error {
    case assetMissing
    case readFailed(String)
}

/// hwp.js(Apache-2.0, `Sources/Resources/web/hwpjs/hwpjs.bundle.js`)로 **구형 `.hwp`(바이너리)**
/// 원본 조판을 그린다. kordoc `render`(hwpx 전용, `KordocRenderService`)와 달리 외부 프로세스를
/// 부르지 않는다 — hwp.js는 순수 JS 엔진이라 실제 파싱·그리기는 **WKWebView 안에서** 일어난다.
/// 이 서비스는 원본 파일 바이트를 읽어 base64로 감싼 HTML을 만들 뿐, 렌더 성공 여부를 Swift가
/// 미리 알 수 없다(파싱이 웹뷰 JS 컨텍스트 안에서 일어나므로). 그래서 실패 안전장치는 HTML
/// 자체에 넣는다 — hwp.js가 던지는 예외를 페이지 안 `try/catch`로 잡아 안내 문구로 바꿔치기한다
/// (Swift `.failed` 상태와 같은 톤: 경고 아이콘 + 안내 + "글로 보기" 안내, `OfficeOriginalRenderPreview`
/// 실패 화면과 시각적으로 맞춤). Swift가 던지는 `.failed`는 파일을 아예 못 읽거나 번들 자산이
/// 없을 때만(진짜 Swift 쪽 실패) 쓴다.
actor HwpJsRenderService {
    /// 렌더 HTML 세션 캐시(키=경로, 값=수정시각+HTML). 같은 파일 재요청 시 재렌더 방지.
    private var htmlCache: [String: (mtime: Date, html: String)] = [:]

    func renderHTML(for fileURL: URL) throws -> String {
        let key = fileURL.path(percentEncoded: false)
        let mtime = (try? FileManager.default.attributesOfItem(atPath: key))?[.modificationDate] as? Date
        if let mtime, let hit = htmlCache[key], hit.mtime == mtime {
            return hit.html
        }

        guard let hwpJsJS = LocalWebAssets.hwpJsJS else { throw HwpJsRenderError.assetMissing }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw HwpJsRenderError.readFailed(error.localizedDescription)
        }

        let html = Self.wrapViewer(base64: data.base64EncodedString(), hwpJsJS: hwpJsJS)
        if let mtime {
            htmlCache[key] = (mtime, html)
        }
        return html
    }

    /// 원본 파일의 base64와 hwp.js 번들을 넣어 WKWebView가 바로 로드할 HTML로 감싼다(순수 함수).
    /// `atob(base64)`로 얻은 "바이너리 문자열"(글자 하나=바이트 하나)을 그대로 `HWPJS.Viewer`에
    /// 넘긴다 — base64 문자열이나 `Uint8Array`를 그대로 넘기면 hwp.js가 내부적으로 쓰는 CFB
    /// 파서가 헤더 시그니처를 잘못 읽는다(실측 확인, 2026-07-30). 렌더 실패(지원 안 하는
    /// 컨트롤·손상 파일 등)는 페이지 안 `try/catch`가 잡아 안내 문구로 바꾼다 — 크래시 없음.
    static func wrapViewer(base64: String, hwpJsJS: String) -> String {
        """
        <html>
        <head><meta charset="utf-8">
        <style>
          body { margin: 0; background: #ffffff; font-family: -apple-system, sans-serif; }
          #fallback { display: none; flex-direction: column; align-items: center; justify-content: center;
                      height: 100vh; color: #666; text-align: center; padding: 24px; box-sizing: border-box; }
          #fallback .icon { font-size: 40px; margin-bottom: 12px; }
        </style>
        </head>
        <body>
        <div id="container"></div>
        <div id="fallback">
          <div class="icon">⚠️</div>
          <div>이 파일은 원본 그대로 보기를 만들 수 없습니다.</div>
          <div style="margin-top: 6px; font-size: 13px;">위 "글로 보기" 버튼을 눌러 변환된 글로 보세요.</div>
        </div>
        <script>\(hwpJsJS)</script>
        <script>
        try {
          var binStr = atob("\(base64)");
          new window.HWPJS.Viewer(document.getElementById('container'), binStr);
        } catch (e) {
          document.getElementById('container').style.display = 'none';
          document.getElementById('fallback').style.display = 'flex';
          console.error('hwp.js render failed:', e);
        }
        </script>
        </body>
        </html>
        """
    }
}
