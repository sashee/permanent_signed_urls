const AWS = require("aws-sdk");
const fs = require("fs").promises;

const s3 = new AWS.S3({
	signatureVersion: "v4",
});

const dynamodb = new AWS.DynamoDB();

module.exports.handler = async (event) => {
	const permalinkPath = /^\/link\/(?<token>[^/]*)$/;
	const revokePermalinkPath = /^\/revoke\/(?<token>[^/]*)$/;

	if (event.requestContext.http.path === "/") {
		const [html, files, permalinksTable] = await Promise.all([
			fs.readFile(__dirname+"/index.html", "utf8"),
			(async () => {
				// does not handle pagination, only for demonstration
				const objects = await s3.listObjectsV2({Bucket: process.env.BUCKET}).promise();
				return objects.Contents.map((object) => {
					return `
<tr>
	<td>${object.Key}</td>
	<td>
		<button data-permalink-key="${encodeURIComponent(object.Key)}" class="create-permalink">Create permalink</button>
	</td>
</tr>
					`;
				}).join("");
			})(),
			(async () => {
				const items = await dynamodb.scan({
					TableName: process.env.TABLE,
				}).promise();

				return items.Items.length > 0 ? items.Items.map(({Token: {S: Token}, Key: {S: Key}}) => `
<tr>
	<td><a target="_blank" href="https://${event.requestContext.domainName}/link/${Token}">Open</a></td>
	<td>${Key}</td>
	<td><button data-token="${Token}" class="revoke">Revoke</button></form>
</td>
</tr>
					`).join("") : "<tr><td colspan=\"3\">No permalinks yet</td></tr>";
			})(),
		]);

		const htmlWithDebug = html.replace("$$FILES_CONTENTS$$", files).replace("$$PERMALINKS_CONTENTS$$", permalinksTable);

		return {
			statusCode: 200,
			headers: {
				"Content-Type": "text/html",
			},
			body: htmlWithDebug,
		};
	} else if (event.requestContext.http.path.match(permalinkPath)) {
		const {token} = event.requestContext.http.path.match(permalinkPath).groups;

		const permalink = await dynamodb.getItem({
			TableName: process.env.TABLE,
			Key: {
				Token: {
					S: token,
				},
			},
		}).promise();

		if (!permalink.Item) {
			return {
				statusCode: 404,
			};
		}

		const key = permalink.Item.Key.S;

		const file = await s3.getSignedUrlPromise("getObject", {Bucket: process.env.BUCKET, Key: key});

		return {
			statusCode: 303,
			headers: {
				Location: file,
			},
		};
	} else if (event.requestContext.http.path === "/create_permalink" && event.requestContext.http.method === "POST" && event.body) {
		const {key} = JSON.parse(event.body);

		// important!
		// make sure that the user has access to the object!

		const token = require("crypto").randomBytes(32).toString("hex");

		await dynamodb.putItem({
			TableName: process.env.TABLE,
			Item: {
				Token: {
					S: token,
				},
				Key: {
					S: key,
				},
			},
		}).promise();
		return {
			statusCode: 200,
		};
	} else if (event.requestContext.http.path.match(revokePermalinkPath) && event.requestContext.http.method === "PUT") {
		const {token} = event.requestContext.http.path.match(revokePermalinkPath).groups;

		await dynamodb.deleteItem({
			TableName: process.env.TABLE,
			Key: {
				Token: {
					S: token,
				},
			},
		}).promise();
		return {
			statusCode: 200,
		};
	}
};
