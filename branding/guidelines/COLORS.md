# PatterOS colour palette

Official visual identity for PatterOS and PatterTech. Inspired by Cherenkov radiation: which is the blue glow produced from charged particles moving through water.

Reference: [Cherenkov radiation palette #1022135](https://www.color-hex.com/color-palette/1022135): *"The colors of Cherenkov radiation illuminating deep water."*

**These colours are reserved.** Third-party forks and products must not use this five-colour scale as their product identity. See [../../TRADEMARK.md](../../TRADEMARK.md).

## Official five-colour scale

Lightest to darkest:

| Name | Hex | RGB |
|------|-----|-----|
| Cherenkov glow | `#33ddff` | (51, 221, 255) |
| Deep sky | `#00bfff` | (0, 191, 255) |
| Azure | `#00a1e6` | (0, 161, 230) |
| Cerulean | `#008bd1` | (0, 139, 209) |
| Deep water | `#0071c2` | (0, 113, 194) |

## Usage

- **Primary accents:** `#00bfff` or `#33ddff` for highlights, links, and active UI elements
- **Depth and backgrounds:** darker stops (`#008bd1`, `#0071c2`) for panels, headers, and depth
- **Neon glow:** combine light stops with a soft outer glow, for example:

  ```css
  box-shadow: 0 0 20px rgba(51, 221, 255, 0.5);
  ```

Complementary accent colours may be used alongside this palette where needed, but the Cherenkov blue scale above is the defining Patter look.
