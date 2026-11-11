"""Search / ask regression tests: retrieval must land on the right take and line."""
import sys, pathlib, json, tempfile
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

from notra import ai, search


def doc(id, title, date, segments, summary=None, project=""):
    return {
        "id": id,
        "title": title,
        "date": date,
        "project": project,
        "duration": 60,
        "segments": segments,
        "summary": {"sections": summary or {}},
    }


LIBRARY = [
    doc("a.ogg", "Sampling plan", "11 Nov · 05:48", [
        {"start": 0, "end": 6, "text": "We looked at the soil sampling grid for the north field."},
        {"start": 6, "end": 14, "text": "The lab will need twelve cores per hectare."},
        {"start": 14, "end": 22, "text": "Ali will order the bags by Friday."},
    ], {"Overview": ["Plan for soil sampling in the north field."],
        "Decisions & actions": ["Ali orders sample bags by Friday."]}, project="Sampling"),
    doc("b.ogg", "Budget review", "12 Nov · 09:10", [
        {"start": 0, "end": 8, "text": "The recorder budget is over by four percent."},
        {"start": 8, "end": 15, "text": "We agreed to move the purchase to next quarter."},
    ], {"Overview": ["Recorder budget is over."]}, project="Work"),
    doc("c.ogg", "Lecture on entropy", "12 Nov · 14:00", [
        {"start": 0, "end": 10, "text": "Entropy is a measure of the number of microstates."},
    ], {"Key concepts": ["Entropy counts microstates."]}),
]


def build():
    index = search.Index()
    index.replace(LIBRARY)
    return index


def main() -> int:
    fails = 0

    def check(label, condition, detail=""):
        nonlocal fails
        print(("ok   " if condition else "FAIL ") + label + (f" — {detail}" if detail and not condition else ""))
        if not condition:
            fails += 1

    # tokenising
    check("words lowercase", search.tokenize("Sampling Plan") == ["sampling", "plan"])
    cjk = search.tokenize("会议纪要")
    check("CJK gets bigrams", "会议" in cjk and "纪要" in cjk, str(cjk))
    check("question filler is dropped",
          search.query_terms("What did we decide about the budget?") ==
          ["decide", "budget"], str(search.query_terms("What did we decide about the budget?")))

    index = build()
    check("index counts documents and passages", index.document_count == 3 and len(index) >= 5,
          f"{index.document_count} docs / {len(index)} passages")

    # retrieval
    hits = index.search("sampling plan")
    check("query lands on the right take", hits and hits[0]["id"] == "a.ogg",
          str([(h["id"], h["score"]) for h in hits]))
    line_hits = index.search("twelve cores per hectare")
    check("a transcript hit carries a timestamp",
          line_hits and line_hits[0]["start"] is not None and line_hits[0]["id"] == "a.ogg",
          str(line_hits[:1]))
    check("project name is searchable", any(h["id"] == "a.ogg" for h in index.search("sampling")))
    check("title outranks a passing mention",
          index.search("budget")[0]["id"] == "b.ogg",
          str([(h["id"], h["score"]) for h in index.search("budget")]))
    check("nothing matches nonsense", index.search("zzzqqq") == [])

    # summary passages are retrievable and marked as such
    summary_hits = index.search("microstates")
    check("summary section is a passage", any(h["start"] is None and h["id"] == "c.ogg"
                                              for h in summary_hits),
          str(summary_hits))

    # speaker change splits passages
    speaker_doc = doc("d.ogg", "Standup", "13 Nov · 09:00", [
        {"start": 0, "end": 3, "text": "First item.", "speaker": "Speaker 1"},
        {"start": 3, "end": 6, "text": "Second item.", "speaker": "Speaker 2"},
    ])
    passages = search.document_passages(speaker_doc)
    check("speaker change starts a new passage", len(passages) == 2, str([p.text for p in passages]))
    check("speaker becomes the passage label", passages[1].section == "Speaker 2")

    # ask: no model -> the matching passages are the answer, never invented text
    original = ai._gguf_llm
    ai._gguf_llm = lambda *a, **k: None
    try:
        result = search.build_answer("who orders the bags", index.search("who orders the bags"))
        check("extractive answer quotes the passage",
              "Ali will order the bags" in result["answer"], result["answer"])
        check("extractive engine is named", result["engine"].startswith("extractive"))
        check("sources keep the take id", result["sources"][0]["id"] == "a.ogg",
              str(result["sources"][:1]))
        check("the cited list and the source flags agree",
              [i + 1 for i, h in enumerate(result["sources"]) if h.get("cited")] == result["cited"],
              str([(i + 1, h.get("cited")) for i, h in enumerate(result["sources"])]))
        empty = search.build_answer("nothing at all", [])
        check("no sources -> no answer", empty["answer"] == "" and empty["engine"] == "none")
    finally:
        ai._gguf_llm = original

    # library loader
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp)
        take = root / "notra-20261111T054800.ogg"
        take.write_bytes(b"OggS-not-a-real-take")
        (root / "notra-20261111T054800.ogg.notes.json").write_text(json.dumps({
            "version": 1,
            "language": "en",
            "duration": 30,
            "template": "meeting",
            "summary": {"sections": {"Overview": ["A loaded sidecar."]}},
            "segments": [{"start": 0, "end": 5, "text": "Loaded from disk."}],
        }), encoding="utf-8")
        (root / "library.json").write_text(json.dumps({
            "projects": ["Sampling"],
            "assignments": {str(take): "Sampling"},
            "titles": {str(take): "Disk take"},
        }), encoding="utf-8")
        docs = search.documents_from_library(root)
        check("library loader reads one take", len(docs) == 1, str(docs))
        check("library loader applies title and project",
              docs[0]["title"] == "Disk take" and docs[0]["project"] == "Sampling", str(docs[:1]))
        check("library loader keeps the transcript", docs[0]["segments"][0]["text"] == "Loaded from disk.")

    print("\nall good" if not fails else f"\n{fails} failure(s)")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
