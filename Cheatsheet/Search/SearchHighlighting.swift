import AppKit
import SwiftUI
import PDFKit

/// Browser-style find colors: yellow for every match, orange for the active one.
enum SearchHighlightColors {
    static let match = NSColor(srgbRed: 1, green: 0.89, blue: 0.36, alpha: 1)
    static let active = NSColor(srgbRed: 1, green: 0.59, blue: 0.2, alpha: 1)
}

/// Wraps matches in <mark> elements inside a rendered page. Matching is per
/// text node (so a match split across elements isn't marked); text inside
/// scripts, styles, SVG and mermaid diagrams is skipped.
nonisolated enum WebSearchHighlighter {
    static func script(for highlight: SearchHighlight?) -> String {
        script(query: highlight?.query ?? "", active: highlight?.activeIndex, marks: true)
    }

    /// Removes any marks and returns how many matches `script` would mark,
    /// without marking them.
    static func countScript(for query: String) -> String {
        script(query: query, active: nil, marks: false)
    }

    private static func script(query: String, active: Int?, marks shouldMark: Bool) -> String {
        let encoded = (try? JSONEncoder().encode(query)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        let active = active.map(String.init) ?? "-1"
        return """
        (function (query, active, shouldMark) {
          document.querySelectorAll('mark[data-cheatsheet-find]').forEach(function (mark) {
            var parent = mark.parentNode;
            parent.replaceChild(document.createTextNode(mark.textContent), mark);
            parent.normalize();
          });
          if (!query || !document.body) return 0;
          var needle = query.toLowerCase();
          var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
            acceptNode: function (node) {
              var el = node.parentElement;
              if (!el || el.closest('script, style, noscript, svg, .mermaid')) return NodeFilter.FILTER_REJECT;
              // Not rendered (display: none), e.g. a web page's closed menus.
              if (!el.getClientRects().length) return NodeFilter.FILTER_REJECT;
              return NodeFilter.FILTER_ACCEPT;
            }
          });
          var nodes = [];
          while (walker.nextNode()) nodes.push(walker.currentNode);
          if (!shouldMark) {
            var count = 0;
            nodes.forEach(function (node) {
              var text = node.nodeValue.toLowerCase();
              for (var at = text.indexOf(needle); at >= 0; at = text.indexOf(needle, at + needle.length)) count++;
            });
            return count;
          }
          var marks = [];
          nodes.forEach(function (node) {
            var current = node;
            var index = current.nodeValue.toLowerCase().indexOf(needle);
            while (index >= 0) {
              var hit = current.splitText(index);
              current = hit.splitText(needle.length);
              var mark = document.createElement('mark');
              mark.setAttribute('data-cheatsheet-find', '');
              hit.parentNode.replaceChild(mark, hit);
              mark.appendChild(hit);
              marks.push(mark);
              index = current.nodeValue.toLowerCase().indexOf(needle);
            }
          });
          marks.forEach(function (mark, i) {
            mark.style.cssText = 'color: black; border-radius: 2px; background: '
              + (i === active ? '\(SearchHighlightColors.activeCSS)' : '\(SearchHighlightColors.matchCSS)');
          });
          if (active >= 0 && marks.length) {
            marks[Math.min(active, marks.length - 1)].scrollIntoView({ block: 'center' });
          }
          return marks.length;
        })(\(encoded), \(active), \(shouldMark));
        """
    }
}

extension SearchHighlightColors {
    nonisolated static let matchCSS = "#ffe35c"
    nonisolated static let activeCSS = "#ff9633"
}

/// Maps PDFKit match selections onto the displayed (possibly /Rotate'd) page.
nonisolated enum PDFMatchGeometry {
    static func unitRects(query: String, url: URL, pageIndex: Int) -> [CGRect] {
        guard
            !query.isEmpty,
            let page = PDFCache.document(at: url)?.page(at: pageIndex)
        else { return [] }
        return PageSearch.pdfSelections(query: query, url: url, pageIndex: pageIndex).map {
            unitRect(for: $0.bounds(for: page), mediaBox: page.bounds(for: .mediaBox), rotation: page.rotation)
        }
    }

    /// `rect` is in PDF page space (bottom-left origin, unrotated media box);
    /// the result is in 0…1 units of the rotated page as displayed, top-left
    /// origin. PDF rotation is clockwise.
    static func unitRect(for rect: CGRect, mediaBox: CGRect, rotation: Int) -> CGRect {
        let width = mediaBox.width
        let height = mediaBox.height
        let degrees = ((rotation % 360) + 360) % 360
        func display(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            switch degrees {
            case 90: CGPoint(x: y, y: width - x)
            case 180: CGPoint(x: width - x, y: height - y)
            case 270: CGPoint(x: height - y, y: x)
            default: CGPoint(x: x, y: y)
            }
        }
        let displayWidth = degrees % 180 == 0 ? width : height
        let displayHeight = degrees % 180 == 0 ? height : width
        let a = display(rect.minX - mediaBox.minX, rect.minY - mediaBox.minY)
        let b = display(rect.maxX - mediaBox.minX, rect.maxY - mediaBox.minY)
        let minX = min(a.x, b.x), maxX = max(a.x, b.x)
        let minY = min(a.y, b.y), maxY = max(a.y, b.y)
        return CGRect(
            x: minX / displayWidth,
            y: 1 - maxY / displayHeight,
            width: (maxX - minX) / displayWidth,
            height: (maxY - minY) / displayHeight
        )
    }
}

/// Match boxes over bitmap content (PDF pages, images) that is aspect-fit
/// into this view's bounds. Rects are unit coordinates, top-left origin.
struct MatchBoxesOverlay: View {
    let unitRects: [CGRect]
    let activeIndex: Int?
    let contentSize: CGSize

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let scale = min(size.width / max(contentSize.width, 1), size.height / max(contentSize.height, 1))
            let fitted = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
            let origin = CGPoint(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2)
            ZStack(alignment: .topLeading) {
                ForEach(Array(unitRects.enumerated()), id: \.offset) { index, rect in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(nsColor: index == activeIndex ? SearchHighlightColors.active : SearchHighlightColors.match))
                        .blendMode(.multiply)
                        .frame(width: rect.width * fitted.width + 2, height: rect.height * fitted.height + 2)
                        .offset(x: origin.x + rect.minX * fitted.width - 1, y: origin.y + rect.minY * fitted.height - 1)
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .allowsHitTesting(false)
    }
}
