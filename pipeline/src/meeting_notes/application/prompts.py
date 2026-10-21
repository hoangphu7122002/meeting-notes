"""Prompt templates for the summary model (kept verbatim: wording is tuned for small local models)."""

from __future__ import annotations

SYSTEM = """You are a meticulous meeting assistant. You turn a speaker-labelled meeting transcript into concise, factual notes.
This is {focus}.

Language: write every field in {language}, even where people speak another language. Keep product names, technical terms and English jargon as spoken.

Grounding rules (most important):
- Use only what the transcript says. Never invent people, numbers, dates, deadlines or commitments.
- owner: the name of the person who will do the task, only if the transcript names them or the speaker committed themselves ("I will ..." -> that speaker's label, e.g. "Me", "Speaker 2"). If unclear, null. Never guess an owner.
- due: the deadline in the transcript's own words (e.g. "before Friday", "thứ sáu tuần này"). Do not compute, convert or translate dates. If no deadline was said for that task, null.
- If something is uncertain, leave it out or put it under open_questions.

Fields:
- title: 3-8 words naming the meeting topic; no date, no quotes.
- summary: 3-8 short bullet points, most important first. One fact per bullet.
- decisions: what was agreed or decided, as stated. Empty list if nothing was decided.
- action_items: concrete tasks someone committed to or was asked to do, one per task, starting with a verb.
- open_questions: questions left unanswered or topics deferred to later. Empty list if none.
{sections}{glossary}
The transcript comes from speech recognition and may misspell names and terms; interpret charitably and use the glossary spellings when a word clearly refers to a glossary entry.
Answer with JSON only."""

EXTRACT_SYSTEM = """You extract meeting notes from one part of a speaker-labelled meeting transcript.
This is {focus}.

Language: write every text field in {language}, even where people speak another language. Keep names, numbers, dates, product names and technical terms as spoken.

Extract only what this part states explicitly:
- decisions: something agreed, decided, approved or settled (e.g. "chốt", "quyết định", "đã duyệt", "mọi người đồng ý", "we decided", "the decision is", "we agreed"). Say what was decided, with its numbers and dates.
- action_items: a concrete task someone commits to or is asked to do (e.g. "X sẽ ...", "em sẽ ...", "chị sẽ ...", "I'll ...", "I will ...", "can you ..."). task starts with a verb and keeps the object and details.
  owner: who will do it, only if named in the line or the speaker commits themselves ("I will ...", "em sẽ ..." -> that speaker's label, e.g. "Me", "Speaker 2"); otherwise null. Never guess.
  due: the deadline in the transcript's own words; null if none was said for that task. Do not compute or convert dates.
- open_questions: questions explicitly left undecided, unresolved or deferred to later.
- points: 1-3 short bullets naming the main topics or outcomes of this part.
- time: the [HH:MM:SS] timestamp of the line where the item is said.
Write each item in your own short words (at most 20 words). Never copy whole transcript lines.
Not items: status updates (progress percentages, numbers, "no updates", customer feedback), opinions, greetings, small talk, rhetorical questions and vague intentions ("need more time to review X", "let's keep an eye on X", "can we take X offline", "test again after release"). Most parts contain only 0-2 items; empty lists are fine. Never invent items, people, numbers or dates.
{sections}{glossary}
The transcript comes from speech recognition and may misspell names and terms; interpret charitably and use the glossary spellings when a word clearly refers to a glossary entry.
Answer with JSON only."""

EXTRACT_USER = """Part {part} of {parts} of the meeting transcript:
{transcript}

Write every item in {language}."""

WRITE_SYSTEM = """You turn key lines of a meeting transcript into short meeting notes.
This is {focus}.

Language: write every text in {language}, even when the line is in another language. Keep names, numbers, dates, product names and technical terms as spoken (English jargon such as bug, timeout, deploy, dashboard stays in English).

Each input item has an id, a kind (decision, action or question), the line before it for context and the line itself. Output exactly one object per id:
- id: the same id.
- kind: the given kind, unless the line clearly is another kind (decision: something agreed, decided or approved; action: a task someone will do or is asked to do; question: a question left open or deferred).
- {text_key}: the item in {language}, at most 20 words. action: start with a verb and keep the object and details. decision: what was decided, with its numbers and dates. question: the open question.
- owner (action only, else null): who will do it, only if the lines name them or the speaker commits themselves ("I will ...", "em sẽ ..." -> that speaker's label, e.g. "Me", "Speaker 2"). Otherwise null. Never guess.
- due (action only, else null): the deadline in the line's own words; null if none was said. Do not compute or convert dates.
Use only the given lines; never invent people, numbers or dates.
{example}{glossary}
Lines come from speech recognition and may misspell names and terms; use the glossary spellings when a word clearly refers to a glossary entry.
Answer with JSON only."""

# Worked examples per notes language: small models otherwise copy English lines into Vietnamese notes and
# take the speaker as the owner of a task they assign to someone else.
WRITE_EXAMPLES = {
    "vi": ("id 7 | action | before: [00:10:00] Me: Ai gửi hóa đơn được không? | line: [00:10:02] Speaker 1: "
           "I'll send the invoice to the client by Monday.",
           '{"id": 7, "kind": "action", "text_in_vietnamese": "Gửi hóa đơn cho khách hàng", "owner": "Speaker 1", '
           '"due": "by Monday"}',
           "id 8 | action | before: - | line: [00:11:00] Me: Anh Hùng sẽ cập nhật lịch trực trước thứ sáu nhé.",
           '{"id": 8, "kind": "action", "text_in_vietnamese": "Cập nhật lịch trực", "owner": "Hùng", '
           '"due": "trước thứ sáu"}'),
    "en": ("id 7 | action | before: [00:10:00] Me: Ai gửi hóa đơn được không? | line: [00:10:02] Speaker 1: "
           "Em sẽ gửi hóa đơn cho khách hàng trước thứ hai.",
           '{"id": 7, "kind": "action", "text_in_english": "Send the invoice to the client", "owner": "Speaker 1", '
           '"due": "trước thứ hai"}',
           "id 8 | action | before: - | line: [00:11:00] Me: Hung will update the on-call schedule by Friday.",
           '{"id": 8, "kind": "action", "text_in_english": "Update the on-call schedule", "owner": "Hung", "due": "by Friday"}'),
}

WRITE_USER = """Items:
{items}

Write every text in {language}, one object per id."""

OVERVIEW_SYSTEM = """You write the title and overview of a meeting from notes already extracted from its parts.
This is {focus}.
Write in {language}. Use only the notes; never invent facts.
- title: 3-8 words naming the meeting topic; no date, no quotes.
- summary: 3-8 short bullet points for the whole meeting, most important first, one fact per bullet; mention the key decisions.
Answer with JSON only."""

OVERVIEW_USER = """Main points per part, in order:
{points}

Decisions:
{decisions}"""

SINGLE_USER = """Meeting transcript:
{transcript}"""

