import Foundation

enum HwpConvertRenderError: Error {
    case assetMissing
    case readFailed(String)
}

/// hwp-convert(MIT, `Sources/Resources/web/hwpconvert/hwpconvert.bundle.js`)로 **구형 `.hwp`
/// (바이너리)** 원본을 실제 서식 있는 HTML로 그린다. hwp-convert는 rhwp(Rust, MIT, Edward Kim의
/// HWP 5.0 CFB 바이너리 파서를 TS로 포팅)와 hwpxjs(MIT, ssabro)를 잇는 프로젝트로, HWP를
/// HWPX(개방형 OWPML)로 변환한 뒤 그 HWPX를 진짜 서식 있는 HTML(표·굵게·색·정렬 보존)로 뽑아낸다.
/// kordoc `render`(hwpx 전용, `KordocRenderService`)와 달리 외부 프로세스를 부르지 않는다 —
/// 변환·추출이 전부 **WKWebView 안 JS**에서 일어난다(Node 프로세스 호출 없음). 실측 확인
/// (2026-07-30): 레고 실제 정치·행정 문서 4건 전부 표·색·문단 구조까지 깨끗하게 재현됨 —
/// 초기에 검토했던 `hwp.js`(DOM 직접 그리기, 2022년 이후 미관리)보다 신뢰도가 높고, kordoc의
/// `render`(SVG, 조판 캐시 없는 파일은 reflow) 경로로 우회했을 때 나타난 한글 폰트 대체
/// 글자 겹침 문제도 없다(HTML+CSS라 시스템 폰트로 자연스럽게 대체됨).
/// 이 서비스는 원본 파일 바이트를 읽어 base64로 감싼 HTML을 만들 뿐, 변환·추출 성공 여부를
/// Swift가 미리 알 수 없다(전부 웹뷰 JS 컨텍스트 안에서 일어나므로). 그래서 실패 안전장치는
/// HTML 자체에 넣는다 — hwp-convert가 던지는 예외를 페이지 안 `try/catch`로 잡아 안내 문구로
/// 바꿔치기한다(Swift `.failed` 상태와 같은 톤). Swift가 던지는 `.failed`는 파일을 아예
/// 못 읽거나 번들 자산이 없을 때만(진짜 Swift 쪽 실패) 쓴다.
actor HwpConvertRenderService {
    /// 렌더 HTML 세션 캐시(키=경로, 값=수정시각+HTML). 같은 파일 재요청 시 재렌더 방지.
    private var htmlCache: [String: (mtime: Date, html: String)] = [:]

    func renderHTML(for fileURL: URL) throws -> String {
        let key = fileURL.path(percentEncoded: false)
        let mtime = (try? FileManager.default.attributesOfItem(atPath: key))?[.modificationDate] as? Date
        if let mtime, let hit = htmlCache[key], hit.mtime == mtime {
            return hit.html
        }

        guard let hwpConvertJS = LocalWebAssets.hwpConvertJS else { throw HwpConvertRenderError.assetMissing }

        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw HwpConvertRenderError.readFailed(error.localizedDescription)
        }

        let html = Self.wrapExtractor(base64: data.base64EncodedString(), hwpConvertJS: hwpConvertJS)
        if let mtime {
            htmlCache[key] = (mtime, html)
        }
        return html
    }

    /// 원본 파일의 base64와 hwp-convert 번들을 넣어 WKWebView가 바로 로드할 HTML로 감싼다
    /// (순수 함수). `atob(base64)`로 얻은 바이트를 `Uint8Array`로 바꿔 `hwpToHwpx`(HWP→HWPX
    /// 변환) → `new HwpxReader().extractHtml(...)`(HWPX→서식 있는 HTML) 순서로 돌린다.
    /// 변환·추출 실패(암호화 문서·손상 파일 등)는 페이지 안 `try/catch`가 잡아 안내 문구로
    /// 바꾼다 — 크래시 없음.
    static func wrapExtractor(base64: String, hwpConvertJS: String) -> String {
        """
        <html>
        <head><meta charset="utf-8">
        <style>
          body { margin: 0; padding: 16px; background: #ffffff; box-sizing: border-box;
                 font-family: 'Apple SD Gothic Neo', 'Malgun Gothic', sans-serif; }
          .hwpx-table { border-collapse: collapse; }
          .hwpx-table td, .hwpx-table th { border: 1px solid #999; padding: 4px 6px; }
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
        <script>\(hwpConvertJS)</script>
        <script>
        (async () => {
          try {
            var binStr = atob("\(base64)");
            var bytes = new Uint8Array(binStr.length);
            for (var i = 0; i < binStr.length; i++) bytes[i] = binStr.charCodeAt(i);
            var hwpxBytes = await window.HWPCONVERT.hwpToHwpx(bytes, { title: 'preview' });
            var reader = new window.HWPCONVERT.HwpxReader();
            await reader.loadFromArrayBuffer(
              hwpxBytes.buffer.slice(hwpxBytes.byteOffset, hwpxBytes.byteOffset + hwpxBytes.byteLength)
            );
            var html = await reader.extractHtml({
              renderImages: true, renderTables: true, renderStyles: true, embedImages: true
            });
            document.getElementById('container').innerHTML = html;
          } catch (e) {
            document.getElementById('container').style.display = 'none';
            document.getElementById('fallback').style.display = 'flex';
            console.error('hwp-convert render failed:', e);
          }
        })();
        </script>
        </body>
        </html>
        """
    }
}
