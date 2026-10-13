# Media license and upstream credits

The bundled media is distributed under the GNU General Public License, version 3
(GPL-3.0); see [`LICENSE`](LICENSE). The original licenses and attribution below
are retained. This distribution does not remove the upstream permissions.

The villager model and textures come from [Mineclonia](https://git.minetest.land/Mineclonia/Mineclonia)'s
`mobs_mc` mod. The files are renamed with this mod's prefix and are otherwise unchanged. The pulpit
texture is a recolored VoxeLibre texture.

| File | Source | Author | Upstream license |
|------|--------|--------|---------|
| `models/living_villages_villager.b3d` | `mobs_mc/models/mobs_mc_villager.b3d` | 22i | GPL-3.0 |
| `textures/living_villages_villager_*.png` | `mobs_mc` villager base, plains, profession, and tier-badge textures | Mineclonia contributors | MIT |
| `textures/living_villages_pulpit.png` | `mcl_lectern/textures/mcl_lectern_lectern.png` from [VoxeLibre](https://git.minetest.land/VoxeLibre/VoxeLibre) 0.92.3, recolored purple (grayscale, then tinted) | Michieal | [CC-BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) |

The pulpit node uses VoxeLibre's `mcl_lectern_lectern.obj` mesh, which this mod does not copy. Its
`mcl_lectern/README.txt` credits Michieal for the texture and states CC-BY-SA 4 for the media. The
recolored texture is a derivative. GPL-3.0 is applied to this mod's recoloring as
the adapter's license under CC-BY-SA 4.0's ShareAlike compatibility provision;
the original texture remains under CC-BY-SA 4.0. Creative Commons lists GPLv3 as
a [compatible adapter's license](https://creativecommons.org/compatible-licenses/)
and explains [how downstream compliance works](https://wiki.creativecommons.org/wiki/ShareAlike_compatibility:_GPLv3).
The recoloring is a grayscale conversion followed by a purple tint; the editable
PNG is included in `textures/`.

Mineclonia's `mobs_mc/LICENSE-media.md` credits [22i](https://github.com/22i) for the
model and links to the [Blender source repository](https://github.com/22i/minecraft-voxel-blender-models).
It also puts any texture it does not list separately under the MIT License.
The villager textures fall under that MIT grant and are included in this GPL-3.0
distribution with the MIT permission and warranty notice retained below.

## MIT notice for the villager textures

Attribution: Mineclonia contributors, as credited above.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
