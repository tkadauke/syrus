//go:build unix

package mirror

import "syscall"

// volumeSpace reports the total and free bytes of the filesystem holding dir,
// or zeros when it cannot be read.
func volumeSpace(dir string) (total, free uint64) {
	var stat syscall.Statfs_t
	if err := syscall.Statfs(dir, &stat); err != nil {
		return 0, 0
	}
	blockSize := uint64(stat.Bsize)
	return uint64(stat.Blocks) * blockSize, uint64(stat.Bavail) * blockSize
}
