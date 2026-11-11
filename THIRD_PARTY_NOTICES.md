# Third-party notices

## morphnext

Upstream: <https://github.com/KickNext/morphnext>, version 0.7.1.

Morpheum's outline geometry is ported to Swift from morphnext's
`lib/src/geometry/shape.dart`, `resample.dart` and `morph_plan.dart`
(arc-length sampling with corners kept, filled-outline topology, contour
matching by role, FFT circular alignment, and polar interpolation), and its
public outline API (`MorphOutline`, `MorphOutlinePlan`) follows morphnext's
glyph API. Changes: Swift value types in place of Dart buffers, outlines read
from `CGPath` (CoreText glyphs) instead of morphnext's font reader, which is
not ported. Each ported file names its source.

```text
MIT License

Copyright (c) 2026 KickNext

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Morphicons

Upstream: <https://github.com/guillermolg00/morphicons>, revision
`2cdc9292c2b6165274d34ea16909a941cf550cab`.

morphnext adapts its arc-length sampling (`src/core/resample.ts`),
correspondence (`src/core/plan.ts`) and polar interpolation
(`src/core/interpolate.ts`) from Morphicons, so the Swift port carries them
too.

```text
MIT License

Copyright (c) 2026 Guillermo

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Test fonts

`Tests/MorpheumTests/Fixtures` bundles Fraunces (© 2020 The Fraunces
Project Authors) and Red Hat Display (© 2021 Red Hat, Inc., Reserved Font
Name "Red Hat", included unmodified), both under the SIL Open Font License
1.1; their licences sit beside them. They are used only by the tests.
