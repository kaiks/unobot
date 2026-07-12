# Human Uno transcript fixtures

These strings are copied from the frozen human protocol and notification code
at host commit `f409d7a22fe63d899b546effda1e0528ebbead16` and its accepted Jedna commit
`17ada2012112abf1df2cd2a31342fcad2f3ed18a`. Control-code card rendering is
stored as JSON Unicode escapes. Player/card values vary only to make a small,
deterministic transcript.

The fixtures contain public channel messages and private notices separately;
tests must never deliver a private event whose recipient is not the client.
