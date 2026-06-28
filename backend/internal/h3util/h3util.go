package h3util

import h3 "github.com/uber/h3-go/v4"

// Resolution is the res-10 grid Rev plays on (REF: docs/game-design.md §The Grid)
const Resolution = 10

// TileWindowParentResolution is the coarser parent cell used for map-window lookups
// one res-8 parent contains roughly 49 res-10 play cells
const TileWindowParentResolution = 8

func toCell(id uint64) h3.Cell { return h3.Cell(id) }
func toID(c h3.Cell) uint64    { return uint64(c) }

// LatLngToCell returns the res-10 cell containing a coordinate
// mirrors SwiftyH3's throwing `cell(at:)`
func LatLngToCell(lat, lng float64) (id uint64, ok bool) {
	c, err := h3.LatLngToCell(h3.NewLatLng(lat, lng), Resolution)
	if err != nil {
		return 0, false
	}
	return toID(c), true
}

// CellCenter returns a cell's center coordinate in degrees
func CellCenter(id uint64) (lat, lng float64, ok bool) {
	ll, err := h3.CellToLatLng(toCell(id))
	if err != nil {
		return 0, 0, false
	}
	return ll.Lat, ll.Lng, true
}

// Boundary returns a cell's vertex ring as [lat, lng] pairs in degrees,
// used for drawing the hexagon as a polygon on a map
func Boundary(id uint64) (verts [][2]float64, ok bool) {
	b, err := h3.CellToBoundary(toCell(id))
	if err != nil {
		return nil, false
	}
	verts = make([][2]float64, len(b))
	for i, ll := range b {
		verts[i] = [2]float64{ll.Lat, ll.Lng}
	}
	return verts, true
}

// GridDistance is the grid-step distance between two cells
func GridDistance(a, b uint64) (dist int, ok bool) {
	d, err := h3.GridDistance(toCell(a), toCell(b))
	if err != nil {
		return 0, false
	}
	return d, true
}

// GridDisk returns the cell plus all cells within k grid steps (includes origin)
func GridDisk(origin uint64, k int) (cells []uint64, ok bool) {
	disk, err := h3.GridDisk(toCell(origin), k)
	if err != nil {
		return nil, false
	}
	return toIDs(disk), true
}

// Parent returns the ancestor cell at the requested resolution
func Parent(id uint64, resolution int) (parent uint64, ok bool) {
	p, err := toCell(id).Parent(resolution)
	if err != nil {
		return 0, false
	}
	return toID(p), true
}

// GridRing returns the cells exactly k grid steps from origin
func GridRing(origin uint64, k int) (cells []uint64, ok bool) {
	ring, err := h3.GridRing(toCell(origin), k)
	if err != nil {
		return nil, false
	}
	return toIDs(ring), true
}

// GridPath returns the line of cells from a to b inclusive
func GridPath(a, b uint64) (cells []uint64, ok bool) {
	path, err := h3.GridPath(toCell(a), toCell(b))
	if err != nil {
		return nil, false
	}
	return toIDs(path), true
}

func toIDs(cells []h3.Cell) []uint64 {
	out := make([]uint64, len(cells))
	for i, c := range cells {
		out[i] = toID(c)
	}
	return out
}
