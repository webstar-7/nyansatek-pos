exports.handler = async (event) => {
  if (event.httpMethod !== "POST") {
    return { statusCode: 405, body: "Method not allowed" };
  }
  try {
    const { phone, message } = JSON.parse(event.body || "{}");
    if (!phone || !message) {
      return { statusCode: 400, body: JSON.stringify({ error: "phone and message are required" }) };
    }

    const clientId = process.env.HUBTEL_CLIENT_ID;
    const clientSecret = process.env.HUBTEL_CLIENT_SECRET;
    const senderId = process.env.HUBTEL_SENDER_ID || "NYANSATEK";

    if (!clientId || !clientSecret) {
      return { statusCode: 500, body: JSON.stringify({ error: "SMS not configured" }) };
    }

    const url = `https://smsc.hubtel.com/v1/messages/send?clientsecret=${encodeURIComponent(clientSecret)}&clientid=${encodeURIComponent(clientId)}&from=${encodeURIComponent(senderId)}&to=${encodeURIComponent(phone)}&content=${encodeURIComponent(message)}`;

    const res = await fetch(url);
    const data = await res.json().catch(() => ({}));

    if (!res.ok) {
      return { statusCode: 502, body: JSON.stringify({ error: "Hubtel SMS failed", detail: data }) };
    }
    return { statusCode: 200, body: JSON.stringify({ ok: true }) };
  } catch (err) {
    return { statusCode: 500, body: JSON.stringify({ error: err.message }) };
  }
};
