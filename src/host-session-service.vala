namespace Frida {
	public class HostSessionService : Object {
		private Gee.ArrayList<HostSessionBackend> backends = new Gee.ArrayList<HostSessionBackend> ();

		public signal void provider_available (HostSessionProvider provider);
		public signal void provider_unavailable (HostSessionProvider provider);

		private delegate void NotifyCompleteFunc ();

		public HostSessionService.with_default_backends () {
			add_local_backends ();
			add_backend (new FruityHostSessionBackend ());
			add_backend (new DroidyHostSessionBackend ());
			add_backend (new TcpHostSessionBackend ());
		}

		public HostSessionService.with_local_backend_only () {
			add_local_backends ();
		}

		public HostSessionService.with_tcp_backend_only () {
			add_backend (new TcpHostSessionBackend ());
		}

		private void add_local_backends () {
#if WINDOWS
			add_backend (new WindowsHostSessionBackend ());
#endif
#if DARWIN
			add_backend (new DarwinHostSessionBackend ());
#endif
#if LINUX
			add_backend (new LinuxHostSessionBackend ());
#endif
#if QNX
			add_backend (new QnxHostSessionBackend ());
#endif
		}

		public async void start () {
			var remaining = backends.size;

			NotifyCompleteFunc on_complete = () => {
				remaining--;
				if (remaining == 0)
					start.callback ();
			};

			foreach (var backend in backends)
				perform_start.begin (backend, on_complete);

			yield;
		}

		public async void stop () {
			var remaining = backends.size;

			NotifyCompleteFunc on_complete = () => {
				remaining--;
				if (remaining == 0)
					stop.callback ();
			};

			foreach (var backend in backends)
				perform_stop.begin (backend, on_complete);

			yield;
		}

		private async void perform_start (HostSessionBackend backend, NotifyCompleteFunc on_complete) {
			yield backend.start ();
			on_complete ();
		}

		private async void perform_stop (HostSessionBackend backend, NotifyCompleteFunc on_complete) {
			yield backend.stop ();
			on_complete ();
		}

		public void add_backend (HostSessionBackend backend) {
			backends.add (backend);
			backend.provider_available.connect ((provider) => {
				provider_available (provider);
			});
			backend.provider_unavailable.connect ((provider) => {
				provider_unavailable (provider);
			});
		}

		public void remove_backend (HostSessionBackend backend) {
			backends.remove (backend);
		}
	}

	public interface HostSessionProvider : Object {
		public abstract string id {
			get;
		}

		public abstract string name {
			get;
		}

		public abstract ImageData? icon {
			get;
		}

		public abstract HostSessionProviderKind kind {
			get;
		}

		public abstract async HostSession create (string? location = null) throws Error;
		public abstract async void destroy (HostSession session) throws Error;
		public signal void host_session_closed (HostSession session);

		public abstract async AgentSession obtain_agent_session (HostSession host_session, AgentSessionId agent_session_id) throws Error;
		public signal void agent_session_closed (AgentSessionId id);
	}

	public enum HostSessionProviderKind {
		LOCAL_SYSTEM,
		LOCAL_TETHER,
		REMOTE_SYSTEM
	}

	public interface HostSessionBackend : Object {
		public signal void provider_available (HostSessionProvider provider);
		public signal void provider_unavailable (HostSessionProvider provider);

		public abstract async void start ();
		public abstract async void stop ();
	}

	public abstract class BaseDBusHostSession : Object, HostSession {
		public signal void agent_session_opened (AgentSessionId id, AgentSession session);
		public signal void agent_session_closed (AgentSessionId id, AgentSession session);

		private Gee.ArrayList<Entry> entries = new Gee.ArrayList<Entry> ();
		private Gee.HashMap<uint, Gee.Promise<uint>> pending_attach_requests = new Gee.HashMap<uint, Gee.Promise<uint>> ();
		private uint last_session_id = 0;

		public virtual async void close () {
			while (!pending_attach_requests.is_empty) {
				var iterator = pending_attach_requests.values.iterator ();
				iterator.next ();
				var attach_request = iterator.get ();
				try {
					yield attach_request.future.wait_async ();
				} catch (Gee.FutureError e) {
				}
			}

			foreach (var entry in entries.slice (0, entries.size))
				yield entry.close ();
			entries.clear ();
		}

		protected abstract async AgentSession create_system_session () throws Error;

		protected void release_system_session () {
			foreach (var entry in entries) {
				if (entry.pid == 0) {
					destroy (entry);
					return;
				}
			}
		}

		public abstract async HostApplicationInfo get_frontmost_application () throws Error;

		public abstract async HostApplicationInfo[] enumerate_applications () throws Error;

		public abstract async HostProcessInfo[] enumerate_processes () throws Error;

		public abstract async void enable_spawn_gating () throws Error;

		public abstract async void disable_spawn_gating () throws Error;

		public abstract async HostSpawnInfo[] enumerate_pending_spawns () throws Error;

		public abstract async uint spawn (string path, string[] argv, string[] envp) throws Error;

		public abstract async void input (uint pid, uint8[] data) throws Error;

		public abstract async void resume (uint pid) throws Error;

		public abstract async void kill (uint pid) throws Error;

		public async Frida.AgentSessionId attach_to (uint pid) throws Error {
			foreach (var e in entries) {
				if (e.pid == pid)
					return e.id;
			}

			var attach_request = pending_attach_requests[pid];
			if (attach_request != null) {
				var future = attach_request.future;
				try {
					var handle = yield future.wait_async ();
					return AgentSessionId (handle);
				} catch (Gee.FutureError e) {
					throw (Error) future.exception;
				}
			}
			attach_request = new Gee.Promise<uint> ();
			pending_attach_requests[pid] = attach_request;

			AgentSessionId id;
			try {
				AgentSession session;
				Entry entry;

				if (pid == 0) {
					id = Frida.AgentSessionId (0);
					session = yield create_system_session ();
					entry = new Entry (id, pid, null, null, session);
				} else {
					Object transport;
					var stream = yield perform_attach_to (pid, out transport);

					var cancellable = new Cancellable ();
					var timeout_source = new TimeoutSource.seconds (10);
					timeout_source.set_callback (() => {
						cancellable.cancel ();
						return false;
					});
					timeout_source.attach (MainContext.get_thread_default ());

					DBusConnection connection;
					try {
						connection = yield DBusConnection.new (stream, null, DBusConnectionFlags.NONE, null, cancellable);
						session = yield connection.get_proxy (null, ObjectPath.AGENT_SESSION, DBusProxyFlags.NONE, cancellable);
					} catch (GLib.Error establish_error) {
						if (establish_error is IOError.CANCELLED)
							throw new Error.PROCESS_NOT_RESPONDING ("Timed out while waiting for session to establish");
						else
							throw new Error.PROCESS_NOT_RESPONDING (establish_error.message);
					}
					if (cancellable.is_cancelled ())
						throw new Error.PROCESS_NOT_RESPONDING ("Timed out while waiting for session to establish");

					timeout_source.destroy ();

					id = AgentSessionId (++last_session_id);

					entry = new Entry (id, pid, transport, connection, session);
					connection.closed.connect (on_connection_closed);
				}
				entries.add (entry);

				agent_session_opened (id, session);

				attach_request.set_value (id.handle);
				pending_attach_requests.unset (pid);
			} catch (Error e) {
				attach_request.set_exception (e);
				pending_attach_requests.unset (pid);
				throw e;
			}

			return id;
		}

		protected abstract async IOStream perform_attach_to (uint pid, out Object? transport) throws Error;

		public async AgentSession obtain_agent_session (AgentSessionId id) throws Error {
			foreach (var entry in entries) {
				if (entry.id.handle == id.handle)
					return entry.agent_session;
			}
			throw new Error.INVALID_ARGUMENT ("Invalid session ID");
		}

		private void on_connection_closed (DBusConnection connection, bool remote_peer_vanished, GLib.Error? error) {
			bool closed_by_us = (!remote_peer_vanished && error == null);
			if (closed_by_us)
				return;

			Entry entry_to_remove = null;
			foreach (var entry in entries) {
				if (entry.agent_connection == connection) {
					entry_to_remove = entry;
					break;
				}
			}
			assert (entry_to_remove != null);

			destroy (entry_to_remove);
		}

		private void destroy (Entry entry) {
			var id = entry.id;

			entries.remove (entry);

			entry.close.begin ();
			agent_session_closed (id, entry.agent_session);

			agent_session_destroyed (id);
		}

		private class Entry : Object {
			public AgentSessionId id {
				get;
				construct;
			}

			public uint pid {
				get;
				construct;
			}

			public Object? transport {
				get;
				construct;
			}

			public DBusConnection? agent_connection {
				get;
				construct;
			}

			public AgentSession agent_session {
				get;
				construct;
			}

			private Gee.Promise<bool> close_request;

			public Entry (AgentSessionId id, uint pid, Object? transport, DBusConnection? agent_connection, AgentSession agent_session) {
				Object (id: id, pid: pid, transport: transport, agent_connection: agent_connection, agent_session: agent_session);
			}

			public async void close () {
				if (close_request != null) {
					try {
						yield close_request.future.wait_async ();
					} catch (Gee.FutureError e) {
						assert_not_reached ();
					}
					return;
				}
				close_request = new Gee.Promise<bool> ();

				if (agent_connection != null) {
					try {
						yield agent_connection.close ();
					} catch (GLib.Error agent_conn_error) {
					}
				}

				close_request.set_value (true);
			}
		}
	}
}
