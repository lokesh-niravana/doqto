export default function ChatMockupScreen() {
  return (
    <div className="flex flex-col h-full bg-dark text-white">
      {/* Status bar */}
      <div className="flex items-center justify-between px-5 pt-12 pb-2 text-[10px] text-gray-400">
        <span>9:41</span>
        <div className="flex items-center gap-1">
          <div className="w-4 h-2 border border-gray-400 rounded-sm relative">
            <div className="absolute inset-0.5 bg-green-400 rounded-[1px]" style={{ width: "70%" }} />
          </div>
        </div>
      </div>

      {/* Chat header */}
      <div className="flex items-center gap-3 px-4 py-3 border-b border-white/5">
        <div className="w-9 h-9 rounded-full bg-gradient-to-br from-blue-400 to-blue-600 flex items-center justify-center text-xs font-bold">
          DR
        </div>
        <div className="flex-1">
          <div className="text-sm font-semibold">Dr. Rivera</div>
          <div className="text-[10px] text-green-400 flex items-center gap-1">
            <span className="w-1.5 h-1.5 rounded-full bg-green-400 inline-block" />
            Online
          </div>
        </div>
        <div className="flex items-center gap-1">
          <svg className="w-4 h-4 text-primary" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z" />
          </svg>
          <span className="text-[9px] text-primary font-medium">Encrypted</span>
        </div>
      </div>

      {/* Messages */}
      <div className="flex-1 overflow-hidden px-3 py-4 space-y-3">
        {/* Received message */}
        <div className="flex gap-2 max-w-[85%]">
          <div className="bg-surface rounded-2xl rounded-tl-sm px-3.5 py-2.5">
            <p className="text-[11px] leading-relaxed">
              Patient in Room 204 showing elevated troponin levels. Can you review the ECG results?
            </p>
            <span className="text-[8px] text-gray-500 mt-1 block">9:32 AM</span>
          </div>
        </div>

        {/* Sent message */}
        <div className="flex justify-end">
          <div className="max-w-[85%] bg-primary text-white rounded-2xl rounded-tr-sm px-3.5 py-2.5">
            <p className="text-[11px] leading-relaxed">
              I&apos;ll check right away. Initial troponin was 0.4 ng/mL — ordering a repeat and echo.
            </p>
            <div className="flex items-center justify-end gap-1 mt-1">
              <span className="text-[8px] text-white/70">9:34 AM</span>
              <svg className="w-3 h-3 text-white/70" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3">
                <polyline points="20 6 9 17 4 12" />
              </svg>
            </div>
          </div>
        </div>

        {/* Voice message */}
        <div className="flex gap-2 max-w-[85%]">
          <div className="bg-surface rounded-2xl rounded-tl-sm px-3.5 py-2.5">
            <div className="flex items-center gap-2">
              <div className="w-6 h-6 rounded-full bg-primary/20 flex items-center justify-center">
                <svg className="w-3 h-3 text-primary" viewBox="0 0 24 24" fill="currentColor">
                  <polygon points="5 3 19 12 5 21 5 3" />
                </svg>
              </div>
              <div className="flex items-end gap-[2px]">
                {[3, 5, 8, 4, 7, 9, 6, 3, 5, 7, 4, 6, 8, 5, 3, 4, 6, 3].map((h, i) => (
                  <div
                    key={i}
                    className="w-[3px] rounded-full bg-primary/60"
                    style={{ height: h * 2 }}
                  />
                ))}
              </div>
              <span className="text-[9px] text-gray-500 ml-1">0:12</span>
            </div>
            <span className="text-[8px] text-gray-500 mt-1 block">9:35 AM</span>
          </div>
        </div>

        {/* Sent message with encryption badge */}
        <div className="flex justify-end">
          <div className="max-w-[85%] bg-primary text-white rounded-2xl rounded-tr-sm px-3.5 py-2.5">
            <p className="text-[11px] leading-relaxed">
              Echo confirmed — mild LV wall motion abnormality. Starting heparin protocol.
            </p>
            <div className="flex items-center justify-end gap-1 mt-1">
              <span className="text-[8px] text-white/70">9:38 AM</span>
              <svg className="w-3 h-3 text-white/70" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="3">
                <polyline points="20 6 9 17 4 12" />
              </svg>
            </div>
          </div>
        </div>
      </div>

      {/* Input bar */}
      <div className="px-3 pb-8 pt-2 border-t border-white/5">
        <div className="flex items-center gap-2 bg-surface rounded-full px-4 py-2.5">
          <svg className="w-4 h-4 text-gray-500" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Z" />
            <path d="M19 10v2a7 7 0 0 1-14 0v-2" />
            <line x1="12" x2="12" y1="19" y2="22" />
          </svg>
          <span className="text-[11px] text-gray-500 flex-1">Type a message...</span>
          <svg className="w-4 h-4 text-primary" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
            <line x1="22" x2="11" y1="2" y2="13" />
            <polygon points="22 2 15 22 11 13 2 9 22 2" />
          </svg>
        </div>
      </div>
    </div>
  );
}
