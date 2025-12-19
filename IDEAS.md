# IDEAS & TODO

Future features, improvements, and inspiration for the text adventure platform.

## WorldBuilder Enhancements

- [ ] **Avatar/Personality System**: Add the ability to create/select an avatar to use in the WorldBuilder, this will set the personality of the UI and the AI
  - Different avatar personalities could have different speaking styles (formal, casual, whimsical, technical)
  - UI theme variations based on avatar (color schemes, fonts, terminology)
  - AI assistant adapts tone and suggestions to match avatar personality
  - Examples: "The Storyteller" (narrative focus), "The Architect" (technical/systematic), "The Jester" (playful/creative)

## WorldBuilder Technical Improvements

- [ ] **Undo/Redo WebSocket Updates**: Implement proper DOM updates for undo/redo operations
  - Currently undo/redo don't broadcast WebSocket updates
  - Need to modify server-side undo/redo to send DOM update messages
  - Should work the same as create/update/delete operations

## Future Ideas

