import std.stdio;
import upromised.tcp : TcpSocket;
import deimos.libuv.uv : uv_loop_t, uv_default_loop, uv_run, uv_run_mode;

int main() {
	uv_loop_t* loop = uv_default_loop();
	TcpSocket a = new TcpSocket(loop);
	a.bind("127.0.0.1", 3000);
	a.listen(128).each((conn) {
		conn.read().each((d) => conn.write(d.idup)).then((bool) => conn.shutdown).then(() => conn.close);
	}).then((bool) {
		a.close();
	});
	return uv_run(loop, uv_run_mode.UV_RUN_DEFAULT);
}