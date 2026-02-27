# Architecture Diagram Instructions

Generate **three separate diagrams** (SVG or PNG), one per operational flow. Each diagram is self-contained with only the components involved in that flow. This avoids the clutter problem of cramming 20+ elements into a single image.

---

## GLOBAL STYLE (applies to all three diagrams)

- **Orientation:** Landscape, left-to-right. Entry on the left, terminal destinations on the right.
- **Aspect ratio:** Roughly 1400x500 logical units per diagram.
- **Icons:** AWS Architecture Icons (2024 or later).
- **Background:** White or very light gray.
- **Font:** Sans-serif. 12pt for primary labels, 9pt for sub-labels.
- **Arrows:** Orthogonal (horizontal and vertical segments only), rounded corners at bends. No diagonal lines.
- **Arrow labels:** Placed at the midpoint of the line, not overlapping any icon.
- **Containing boxes:** Rounded rectangles, light fill (pale blue/green/gray), 1px border, bold label at top-left inside the box.
- **Spacing:** Minimum 60px between elements. No overlapping labels. No label truncation.
- **Return paths:** Where an output flows back toward the left (e.g., SES Outbound → External Sender), draw it as a separate line curving below the forward path. Label it clearly.

---

## DIAGRAM 1 — Inbound Email Flow

**Filename:** `inbound-flow.svg`

This diagram shows what happens when an external sender emails stephen.abbot@denverbytes.com.

### Elements (left to right)

| Position | Element | Label |
|----------|---------|-------|
| Left edge | Person icon | **External Sender** |
| Column 2 | Route 53 icon | **Route 53** / sub-label: "MX: denverbytes.com" |
| Column 3 | SES icon | **SES Inbound** / sub-label: "Inbound Rule" |
| Column 4 | Lambda icon | **inbound-handler** |
| Column 5 top | SQS icon | **ack-queue** |
| Column 5 bottom | SQS icon | **forward-queue** |
| Beside ack-queue | Small SQS icon (dashed border) | **ack-DLQ** |
| Beside forward-queue | Small SQS icon (dashed border) | **forward-DLQ** |
| Column 6 top | Lambda icon | **ack-sender** |
| Column 6 bottom | Lambda icon | **forward-sender** |
| Column 7 | SES icon | **SES Outbound** |
| Right edge top | Person icon | **External Sender** (receives ack) |
| Right edge bottom | Person icon | **Private Mailbox (Yahoo)** (receives forward) |

### Storage sidebar (right of inbound-handler, vertically stacked)

| Element | Label |
|---------|-------|
| S3 icon | **S3 Bucket** |
| Text list inside S3 box | staging/ · conversations/ · attachments/ · spam/ |
| DynamoDB icon | **Conversations Table** |
| SSM icon | **SSM Parameter Store** / sub-label: "spam keywords path" |

### Arrows — Happy path (solid blue)

1. External Sender → Route 53 → SES Inbound
2. SES Inbound → S3 staging/ (labeled "stores raw email")
3. SES Inbound → inbound-handler (labeled "invokes")
4. inbound-handler → S3 conversations/ (labeled "archive")
5. inbound-handler → S3 attachments/ (labeled "save attachments")
6. inbound-handler → DynamoDB (labeled "store/update conversation")
7. inbound-handler → forward-queue (labeled "always")
8. forward-queue → forward-sender → SES Outbound → Private Mailbox (Yahoo)

### Arrows — First contact branch (solid blue, dashed variation)

9. inbound-handler → ack-queue (labeled "if first contact")
10. ack-queue → ack-sender → SES Outbound → External Sender (labeled "acknowledgement")

### Arrows — Spam branch (solid red)

11. inbound-handler → S3 spam/ (labeled "if spam — archive & stop")

### Arrows — Spam keyword lookup (dashed gray)

12. inbound-handler → SSM (labeled "get S3 key")
13. inbound-handler → S3 spam-filter/ (labeled "load keywords")

### Arrows — DLQ (dashed gray)

14. ack-queue → ack-DLQ (labeled "after 5 failures")
15. forward-queue → forward-DLQ (labeled "after 5 failures")

---

## DIAGRAM 2 — Reply Flow

**Filename:** `reply-flow.svg`

This diagram shows what happens when the private mailbox owner replies via the thread address.

### Elements (left to right)

| Position | Element | Label |
|----------|---------|-------|
| Left edge | Person icon | **Private Mailbox (Yahoo)** |
| Column 2 | Route 53 icon | **Route 53** / sub-label: "MX: thread.denverbytes.com" |
| Column 3 | SES icon | **SES Inbound** / sub-label: "Reply Rule" |
| Column 4 | Lambda icon | **reply-handler** |
| Column 5 | SQS icon | **reply-queue** |
| Beside reply-queue | Small SQS icon (dashed border) | **reply-DLQ** |
| Column 6 | Lambda icon | **reply-sender** |
| Column 7 | SES icon | **SES Outbound** |
| Right edge | Person icon | **External Sender** (receives reply) |

### Storage sidebar (right of reply-handler, vertically stacked)

| Element | Label |
|---------|-------|
| S3 icon | **S3 Bucket** |
| Text list inside S3 box | staging/ · conversations/ |
| DynamoDB icon | **Conversations Table** |

### Arrows (solid green)

1. Private Mailbox → Route 53 → SES Inbound
2. SES Inbound → S3 staging/ (labeled "stores raw email")
3. SES Inbound → reply-handler (labeled "invokes")
4. reply-handler → DynamoDB (labeled "lookup senderEmail + update metadata")
5. reply-handler → S3 conversations/ (labeled "archive")
6. reply-handler → reply-queue
7. reply-queue → reply-sender → SES Outbound → External Sender (labeled "reply delivered")

### Arrows — DLQ (dashed gray)

8. reply-queue → reply-DLQ (labeled "after 5 failures")

---

## DIAGRAM 3 — Monitoring, Alarming & Attachment Extraction

**Filename:** `monitoring-and-extraction.svg`

This diagram shows the observability layer and the attachment extraction sidecar flow.

### Attachment extraction (top band)

| Position | Element | Label |
|----------|---------|-------|
| Left | S3 icon | **S3 Bucket** / sub-label: "attachments/*.pdf, *.docx" |
| Center | Lambda icon | **attachment-extractor** |
| Right | S3 icon | **S3 Bucket** / sub-label: "extracted-text/" |

### Arrows — Extraction (solid orange)

1. S3 attachments/ → attachment-extractor (labeled "S3 ObjectCreated event")
2. attachment-extractor → S3 extracted-text/ (labeled "write extracted text")

### Monitoring and alarming (bottom band)

| Position | Element | Label |
|----------|---------|-------|
| Left (stacked vertically) | 6 small Lambda icons or a single grouped Lambda icon | **All 6 Lambdas** |
| Center top | CloudWatch Logs icon | **7 Log Groups** / sub-label: "6 Lambda + 1 spam" |
| Center bottom | CloudWatch Alarms icon | **9 Error Alarms** / sub-label: "6 Lambda errors + 3 DLQ depth" |
| Right top | SNS icon | **Alert Topic** |
| Right bottom (stacked) | 3 small SQS icons | **3 DLQs** (ack-DLQ, forward-DLQ, reply-DLQ) |
| Far right | Envelope icon | **Alert Email** / sub-label: "abbotnh@yahoo.com" |

### Arrows — Logging (dashed gray)

3. All 6 Lambdas → CloudWatch Logs

### Arrows — Alarming (solid red)

4. 6 Lambda functions → CloudWatch Alarms (labeled "Errors metric ≥ 1")
5. 3 DLQs → CloudWatch Alarms (labeled "ApproximateNumberOfMessagesVisible ≥ 1")
6. CloudWatch Alarms → SNS Alert Topic → Alert Email

---

## VALIDATION CHECKLIST

### Diagram 1 — Inbound
- [ ] External Sender, Route 53, SES Inbound, inbound-handler present
- [ ] ack-queue + ack-DLQ + ack-sender present
- [ ] forward-queue + forward-DLQ + forward-sender present
- [ ] SES Outbound with return arrows to External Sender (ack) and Private Mailbox (forward)
- [ ] S3 with staging/, conversations/, attachments/, spam/ prefixes
- [ ] DynamoDB and SSM present
- [ ] Spam branch visually distinct (red)
- [ ] First-contact branch labeled "if first contact"

### Diagram 2 — Reply
- [ ] Private Mailbox, Route 53, SES Inbound (Reply Rule), reply-handler present
- [ ] reply-queue + reply-DLQ + reply-sender present
- [ ] SES Outbound with return arrow to External Sender
- [ ] S3 with staging/, conversations/ prefixes
- [ ] DynamoDB present with "lookup senderEmail" label

### Diagram 3 — Monitoring & Extraction
- [ ] attachment-extractor with S3 input and output
- [ ] All 6 Lambdas represented as log sources
- [ ] 7 Log Groups, 9 Alarms, SNS, Alert Email present
- [ ] 3 DLQs feed into alarm metrics
- [ ] Clear alarm → SNS → email chain
