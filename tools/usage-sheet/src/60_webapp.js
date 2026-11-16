// Web app entry points.

function jsonOutput(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj)).setMimeType(ContentService.MimeType.JSON);
}

function doPost(e) {
  if (!e || !e.postData || typeof e.postData.contents !== "string") return jsonOutput({ ok: false, error: "bad_json" });
  return jsonOutput(handleReport(SpreadsheetApp.getActiveSpreadsheet(), e.postData.contents, Date.now(), Session.getScriptTimeZone()));
}

function doGet() {
  return ContentService.createTextOutput("ok");
}
