import Foundation

/// 파일 확장자 → 문서 종류 단일 판별원.
enum DocumentKind: String, Codable {
    case markdown
    case image
    case pdf
    case office
    case media
    /// 우리가 모르는 형식 — 애플 미리보기(QuickLook)로 보여준다. 읽기 전용.
    case quickLook
}

extension DocumentKind {
    /// 보기를 네이티브 이미지 뷰로 가르는 확장자 집합(소문자).
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "gif"]

    /// 보기를 네이티브 PDF 뷰로 가르는 확장자 집합(소문자).
    static let pdfExtensions: Set<String> = ["pdf"]

    /// 기본(마크다운) 뷰로 여는 텍스트 확장자(소문자) — 파일 연결(기본 앱 등록) 그룹 정의용.
    /// Info.plist 문서형 선언(md/markdown/mdown)과 앱이 여는 txt를 포함한다.
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "txt"]

    /// kordoc으로 마크다운 변환해 보는 한글·오피스 확장자(소문자).
    static let officeExtensions: Set<String> = ["hwp", "hwpx", "hwpml", "doc", "docx", "xls", "xlsx"]

    /// Docufinder 격차 5번(원본 그대로 보기) — macOS 내장 QuickLook이 원본 조판을 그대로
    /// 그릴 수 있는 MS 오피스 확장자만. HWP류(hwp/hwpx/hwpml)는 맥이 아예 모르는 형식이라
    /// QuickLook도 못 그린다 — kordoc→마크다운이 유일한 경로(실측, npx kordoc --help도
    /// SVG·HTML 렌더 출력 없음 — CmdMD-fork_prd.md §10 격차 5 참고).
    static let nativelyRenderableOfficeExtensions: Set<String> = ["doc", "docx", "xls", "xlsx"]

    /// kordoc patch가 서식 보존 라운드트립을 지원하는 확장자(소문자). HWP/HWPX 전용.
    static let patchableExtensions: Set<String> = ["hwp", "hwpx"]

    /// 이 파일이 kordoc patch(편집 후 서식 보존 저장) 대상인가.
    static func isPatchable(_ url: URL) -> Bool {
        patchableExtensions.contains(url.pathExtension.lowercased())
    }

    /// kordoc fill(서식 빈칸 채우기) 대상 확장자(소문자). HWP/HWPX 전용. 출력은 항상 hwpx.
    static let fillableExtensions: Set<String> = ["hwp", "hwpx"]

    /// 이 파일이 kordoc fill(양식 채우기) 대상인가.
    static func isFillable(_ url: URL) -> Bool {
        fillableExtensions.contains(url.pathExtension.lowercased())
    }

    /// AVFoundation이 네이티브 재생하는 음악 확장자(소문자).
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "flac"]

    /// AVFoundation이 네이티브 재생하는 동영상 확장자(소문자).
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// 미디어(음악+동영상) 확장자 합집합.
    static let mediaExtensions: Set<String> = audioExtensions.union(videoExtensions)

    /// 이 파일이 동영상인가 — 미디어 리더 레이아웃 분기용(동영상=좌우 분할, 음악=상단 바).
    static func isVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }

    /// 종류 정렬 순위(F3) — 문서(markdown) → office → pdf → image → media → quickLook.
    /// 글자로 인식되는 비문서 확장자는 init(from:)이 .markdown으로 폴백하고,
    /// 글자로 인식되지 않는 나머지는 .quickLook(맨 끝)으로 간다 — 같은 종류 안에서는
    /// pathExtension 사전순이 2차 키(LibrarySorting 몫).
    var sortRank: Int {
        switch self {
        case .markdown:  return 0
        case .office:    return 1
        case .pdf:       return 2
        case .image:     return 3
        case .media:     return 4
        case .quickLook: return 5
        }
    }

    /// 확장자(대소문자 무시): 이미지 → PDF → 오피스 → 미디어 → 글자 → 미리보기.
    /// 앞 네 갈래를 먼저 확정해야 기존 종류가 새 갈래로 새지 않는다(스펙 §3).
    init(from url: URL) {
        let ext = url.pathExtension.lowercased()
        if DocumentKind.imageExtensions.contains(ext) {
            self = .image
        } else if DocumentKind.pdfExtensions.contains(ext) {
            self = .pdf
        } else if DocumentKind.officeExtensions.contains(ext) {
            self = .office
        } else if DocumentKind.mediaExtensions.contains(ext) {
            self = .media
        } else if QuickLookRouting.opensAsText(extension: ext) {
            self = .markdown
        } else {
            self = .quickLook
        }
    }
}
