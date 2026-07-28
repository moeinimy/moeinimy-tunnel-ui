package job

import (
	"github.com/mhsanaei/3x-ui/v2/config"
	"github.com/mhsanaei/3x-ui/v2/database"
	"github.com/mhsanaei/3x-ui/v2/logger"
	"github.com/mhsanaei/3x-ui/v2/web/service"
)

// BackupJob sends the panel's database to the Telegram admins on a schedule of its own.
//
// The backup used to ride along with the stats notification, on whatever schedule that
// was set to. That made the one job whose whole point is "there is a copy of this server
// somewhere else" a side effect of a job about reporting usage: turn the notification
// off, or move it to every six hours, and the backup silently followed.
type BackupJob struct {
	tgbotService service.Tgbot
}

func NewBackupJob() *BackupJob {
	return new(BackupJob)
}

func (j *BackupJob) Run() {
	enabled, err := j.settingService().GetTgBotBackup()
	if err != nil || !enabled {
		return
	}

	// Fold the write-ahead log into the database file, then read the file back and
	// check it. A backup is only worth having if it restores, and the two ways this one
	// could be silently useless -- WAL frames still outside the .db, or a file that is
	// structurally broken -- are both cheap to rule out here. On failure the backup is
	// SKIPPED rather than sent: a corrupt file in the admin's chat is worse than a gap,
	// because it looks like a backup.
	if err := database.Checkpoint(); err != nil {
		logger.Warning("scheduled backup skipped, checkpoint failed: ", err)
		return
	}
	if err := database.ValidateSQLiteDB(config.GetDBPath()); err != nil {
		logger.Error("scheduled backup SKIPPED, the database did not pass an integrity "+
			"check -- this needs attention, not a retry: ", err)
		return
	}

	j.tgbotService.SendBackupToAdmins()
}

func (j *BackupJob) settingService() *service.SettingService {
	// SettingService is stateless (it reads through to the DB on every call), so a
	// zero value is the whole of it.
	return &service.SettingService{}
}
