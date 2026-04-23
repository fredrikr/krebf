# krebf
A Z-code interpreter in Ruby, (c) Fredrik Ramsberg 2026, MIT License

Sample usage:
```
ruby krebf.rb zork1.z3
```

**Aim**: Full support for v1-v5, v7 and v8 Z-code games, Windows, Linux and Mac, without any dependencies, except for a standard Ruby installation.

**Status**: Support for v1-v5,v7 and v8 Z-code games is complete. Tested on Windows and Linux.

Current limitations:
- Hasn't been tested on Mac.
- When the game uses the read_char opcode (reading individual key strokes), it can't recognize some special keys like cursor keys, but instead you can use this: Shift-E,X,S,D: Cursor keys, Shift-B: backspace (delete last character), Shift-Q: Exit the interpreter immediately.
- No support for timed input.
