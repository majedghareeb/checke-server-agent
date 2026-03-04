
package agent

import (
	"os"
	"path/filepath"
	"syscall"
)

const diskStatsPathEnv = "MONITORING_DISK_PATH"

// getDiskUsage returns disk usage for root filesystem
func (sc *SystemCollector) getDiskUsage() (used int64, total int64, percentage float64) {
	// Explicit override for containerized deployments where host root is bind-mounted.
	overridePath := filepath.Clean(os.Getenv(diskStatsPathEnv))
	if overridePath != "" {
		if used, total, percentage, ok := sc.getDiskUsageForPath(overridePath); ok {
			return used, total, percentage
		}
	}

	candidatePaths := []string{"/"}
	if sc.isRunningInContainer() {
		candidatePaths = append(candidatePaths,
			"/hostfs",
			"/host",
			"/rootfs",
		)
	}

	// In containers, "/" may point to overlay storage (often ~10GB). Use the largest
	// valid candidate as a best-effort host capacity approximation.
	var bestUsed int64
	var bestTotal int64
	var bestPercentage float64
	for _, path := range candidatePaths {
		currentUsed, currentTotal, currentPercentage, ok := sc.getDiskUsageForPath(path)
		if !ok {
			continue
		}
		if currentTotal > bestTotal {
			bestUsed = currentUsed
			bestTotal = currentTotal
			bestPercentage = currentPercentage
		}
	}

	if bestTotal > 0 {
		return bestUsed, bestTotal, bestPercentage
	}

	return 0, 0, 0
}

func (sc *SystemCollector) getDiskUsageForPath(path string) (used int64, total int64, percentage float64, ok bool) {
	if path == "" {
		return 0, 0, 0, false
	}

	info, err := os.Stat(path)
	if err != nil || !info.IsDir() {
		return 0, 0, 0, false
	}

	var stat syscall.Statfs_t
	err = syscall.Statfs(path, &stat)
	if err != nil {
		return 0, 0, 0, false
	}

	total = int64(stat.Blocks) * int64(stat.Bsize)
	if total <= 0 {
		return 0, 0, 0, false
	}

	free := int64(stat.Bavail) * int64(stat.Bsize)
	used = total - free

	percentage = float64(used) / float64(total) * 100.0

	return used, total, percentage, true
}

func (sc *SystemCollector) isRunningInContainer() bool {
	if _, err := os.Stat("/.dockerenv"); err == nil {
		return true
	}
	if _, err := os.Stat("/run/.containerenv"); err == nil {
		return true
	}
	return false
}
