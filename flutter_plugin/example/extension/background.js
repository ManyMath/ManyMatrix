chrome.runtime.onInstalled.addListener(() => {
  chrome.sidePanel.setPanelBehavior({openPanelOnActionClick: true});
});

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type === 'openTab') {
    chrome.tabs.create({url: chrome.runtime.getURL('index.html')});
    sendResponse({ok: true});
  }
});
