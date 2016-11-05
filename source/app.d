import std.stdio;
import upromised.tcp : TcpSocket;
import upromised.dns : getAddrinfo;
import deimos.libuv.uv : uv_loop_t, uv_default_loop, uv_run, uv_run_mode;
import upromised : fatal;
import upromised.promise : Promise;

int main() {
	uv_loop_t* loop = uv_default_loop();
	getAddrinfo(loop, "0.0.0.0", 3000).then((addr) {
		auto a = new TcpSocket(loop);
		a.bind(addr);
		return a.listen(128).each((conn) {
			conn.read().each((d) => conn.write(d.idup)).then((bool) => conn.shutdown)
			.except((Exception e) {
				import std.stdio : stderr;
				stderr.writeln(e);
			})
			.then(() => conn.close)
			.except((Throwable e) => fatal(e));
		}).then((bool) {
			a.close();
		});
	}).except((Throwable e) => fatal(e));

	return uv_run(loop, uv_run_mode.UV_RUN_DEFAULT);
}