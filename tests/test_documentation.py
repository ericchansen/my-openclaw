"""Keep the human documentation's local navigation usable."""

from pathlib import Path
import re
import unittest
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[1]


class DocumentationTests(unittest.TestCase):
    def test_local_links_and_heading_targets_exist(self):
        for source in [ROOT / "README.md", *sorted((ROOT / "docs").glob("*.md"))]:
            text = source.read_text(encoding="utf-8")
            for link in re.findall(r"(?<!!)\[[^\]]+\]\(([^)]+)\)", text):
                parsed = urlsplit(link)
                if parsed.scheme or parsed.netloc:
                    continue
                with self.subTest(source=source.name, link=link):
                    target = (source.parent / unquote(parsed.path)).resolve() if parsed.path else source
                    self.assertTrue(target.is_file(), f"Missing target: {target}")
                    if parsed.fragment and target.suffix == ".md":
                        headings = re.findall(
                            r"^#{1,6}\s+(.+)$", target.read_text(encoding="utf-8"), re.M)
                        anchors = {
                            re.sub(r"[^\w\- ]", "", heading.lower()).replace(" ", "-")
                            for heading in headings
                        }
                        self.assertIn(unquote(parsed.fragment), anchors)


if __name__ == "__main__":
    unittest.main()
