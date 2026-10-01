# remote/rdp/gfx

Holds the client-side picture of the remote desktop: a premultiplied RGBA framebuffer (alpha 255, red first, top row first -- the layout ui/window's Surface.Present takes) and the rectangles the codecs and the session use to describe damage.

```vertex
import "remote/rdp/gfx"
```

## Types

- **`Rect`** (struct): Rect is a rectangle in framebuffer pixels: X/Y is its top-left corner, the far edges are exclusive.
- **`Framebuffer`** (struct): Framebuffer is the remote desktop's pixels: Width * Height * 4 bytes of premultiplied RGBA, top row first.

Part of the [`remote`](https://github.com/vertex-language/remote) repository.
