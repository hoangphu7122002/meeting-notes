MEETING NOTES - CÀI ĐẶT (Tiếng Việt)

1. Kéo MeetingNotes vào thư mục Applications (biểu tượng bên cạnh).
2. Mở Applications, nhấp đúp MeetingNotes. macOS báo "không thể mở" vì ứng dụng không được Apple
   công chứng (chúng tôi không dùng tài khoản Apple Developer). Bấm "Xong" (Done), KHÔNG chuyển vào Thùng rác.
3. Mở Cài đặt hệ thống > Quyền riêng tư & Bảo mật, cuộn xuống phần Bảo mật, bấm "Vẫn mở" (Open Anyway)
   cạnh dòng MeetingNotes, nhập mật khẩu máy, rồi bấm "Mở". Chỉ cần làm MỘT LẦN cho bản tải về này.
4. Trong cửa sổ Meeting Notes, bấm "Cài đặt (~3,4 GB)". Ứng dụng tự tải mọi thứ (không cần Terminal,
   không cần tài khoản hay token). Cần Ollama cho phần tóm tắt: nếu chưa có, ứng dụng chỉ đường tải bản
   chính thức tại ollama.com.
5. Cho phép Micro khi được hỏi, và bật MeetingNotes trong Cài đặt hệ thống > Quyền riêng tư & Bảo mật >
   Ghi màn hình & âm thanh hệ thống (chỉ thu âm thanh, không lưu hình), rồi mở lại ứng dụng.

Cách khác cho người dùng Terminal (thay cho bước 2-3):
   xattr -dr com.apple.quarantine /Applications/MeetingNotes.app

Yêu cầu: máy Mac Apple Silicon (M1 trở lên), macOS 14 trở lên, ~8 GB dung lượng trống, nên có 16 GB RAM.
Mọi thứ chạy trên máy; âm thanh và ghi chú không rời khỏi máy.


MEETING NOTES - INSTALL (English)

1. Drag MeetingNotes onto the Applications folder next to it.
2. Open Applications and double-click MeetingNotes. macOS says it cannot be opened because the app is not
   notarized by Apple (no Apple Developer account). Click "Done"; do NOT move it to the Trash.
3. Open System Settings > Privacy & Security, scroll to Security, click "Open Anyway" next to MeetingNotes,
   enter your Mac password, then "Open". Needed ONCE for this download.
4. In the Meeting Notes window click "Set up (~3.4 GB)". The app downloads everything itself (no Terminal,
   no account, no token). Summaries need Ollama: if it is missing, the app links to the official download
   at ollama.com.
5. Allow the Microphone when asked, and enable MeetingNotes in System Settings > Privacy & Security >
   Screen & System Audio Recording (audio only, no screen content is saved), then reopen the app.

Terminal alternative to steps 2-3:
   xattr -dr com.apple.quarantine /Applications/MeetingNotes.app

Requires an Apple Silicon Mac (M1 or later), macOS 14 or later, ~8 GB free disk, 16 GB RAM recommended.
Everything runs on this Mac; audio and notes never leave it.
