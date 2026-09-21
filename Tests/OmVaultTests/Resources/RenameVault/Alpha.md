# Alpha

Alpha links to Beta in every shape:

- plain: [[Beta]]
- alias: [[Beta|друг]]
- anchor: [[Beta#Раздел]]
- anchor with alias: [[Beta#Раздел|оба сразу]]
- explicit extension: [[Beta.md]]
- lowercase spelling: [[beta]]
- a note that does not exist: [[Ghost]]

Inline code must survive untouched: `[[Beta]]`

```markdown
A fenced block is verbatim text, not a link:
[[Beta]]
[[Beta|друг]]
```

    An indented code block is verbatim too:
    [[Beta]]
