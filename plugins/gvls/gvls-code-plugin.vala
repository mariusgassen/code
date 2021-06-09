/* gvls-sourceview.vala
 *
 * Copyright 2021 Daniel Espinosa <esodan@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * Author: Daniel Espinosa <esodan@gmail.com>
 */

public class Scratch.Plugins.GVlsCompletion : Peas.ExtensionBase, Peas.Activatable {
    private MainWindow main_window;
    private ulong hook_document_handle = 0;
    private uint timed_id = 0;
    private bool lsp_sync_in_progress = false;
    private bool initiated = false;

    public Object object { owned get; construct; }
    Scratch.Services.Interface plugins;

    ~GVlsCompletion () {
        if (timed_id != 0) {
            var source = MainContext.@default ().find_source_by_id (timed_id);
            if (source != null) {
                source.destroy ();
            }
        }
    }

    public void activate () {
        plugins = (Scratch.Services.Interface) object;

        GVlsp.ServerInetLocal server = new GVlsp.ServerInetLocal ();

        server.run ();
        server.target_manager.add_default_vapi_dirs ();
        plugins.set_data<GVls.Server> ("gvls-server", server);
        plugins.set_data<GVls.Client> ("gvls-client", new GVlsp.ClientInetLocal ());

        timed_id = Timeout.add (1000, push_document_changes);

        plugins.hook_window.connect ((w) => {
            this.main_window = w;
        });
        hook_document_handle = plugins.hook_document.connect ((doc) => {
            var project = doc.source_view.project;
            if (project == null) {
                return;
            } else {
                var project_path = project.top_level_path;
                if (project_path == null) {
                    return;
                }

                var gvls_manager = project.get_data<GVlsp.ProjectManager> ("gvls-manager");
                if (gvls_manager == null) {
                    var project_file = GLib.File.new_for_path (project.top_level_path);
                    gvls_manager = new GVlsp.ProjectManager (
                        project_file,
                        new GVlsp.BuildSystemMesonVala (project_file)
                    );
                    project.set_data<GVlsp.ProjectManager> ("gvls-manager", gvls_manager);

                    gvls_manager.client_initialized.connect (() => {
                    });

                    gvls_manager.initialize_inet_manager.begin ((obj, res) => {
                        try {
                            gvls_manager.initialize_inet_manager.end (res);
                            init_doc (doc);
                        } catch (Error e) {
                            warning ("Error initializing gvls project manager: %s", e.message);
                        }
                    });
                }
            }
        });
    }

    private void init_doc (Scratch.Services.Document doc) throws GLib.Error {
        var view = doc.source_view;
        var gvls_provider = view.get_data<GVlsui.CompletionProvider> ("gvls-provider");
        if (gvls_provider != null) {
            return;
        }

        var completion_provider = new GVlsui.CompletionProvider ();
        var gvls_manager = doc.source_view.project.get_data<GVlsp.ProjectManager> ("gvls_manager");
        completion_provider.manager = gvls_manager;

        view.get_completion ().add_provider (completion_provider);
        view.set_data<GVlsui.CompletionProvider> ("gvls-provider", completion_provider);
        view.set_data<bool> ("gvls-view-dirty", true);
        GVls.Container changes = new GVls.ContainerHashList.for_type (typeof (GVls.TextDocumentContentChangeEventInfo));
        view.set_data<GVls.Container> ("gvls-changes", changes);
        var buffer = view.get_buffer ();
        buffer.delete_range.connect ((start, end)=>{
            var gvls_changes = view.get_data<GVls.Container> ("gvls-changes");
            var start_pos = new GVls.SourcePosition.from_values (start.get_line (), start.get_line_offset ());
            var end_pos = new GVls.SourcePosition.from_values (end.get_line (), end.get_line_offset ());
            var content_change = new GVls.TextDocumentContentChangeEventInfo ();
            content_change.range.start = start_pos;
            content_change.range.end = end_pos;
            content_change.text = null;
            gvls_changes.add (content_change);
        });

        buffer.insert_text.connect ((ref pos, _text)=>{
            var gvls_changes = view.get_data<GVls.Container> ("gvls-changes");
            var start_pos = new GVls.SourcePosition.from_values (pos.get_line (), pos.get_line_offset ());
            var end_pos = new GVls.SourcePosition.from_values (pos.get_line (), pos.get_line_offset ());
            var content_change = new GVls.TextDocumentContentChangeEventInfo ();
            content_change.range.start = start_pos;
            content_change.range.end = end_pos;
            content_change.text = _text;
            gvls_changes.add (content_change);
        });

        gvls_manager.client.document_open.begin (doc.file.get_uri (), buffer.text, (obj, res)=>{
            try {
                gvls_manager.client.document_open.end (res);
            } catch (GLib.Error e) {
                warning ("Error while send didOpen notification: %s", e.message);
            }
        });
    }

    public void deactivate () {
        plugins.disconnect (hook_document_handle);
        if (main_window == null) {
            message ("No MainWindow was set");
            return;
        }

        foreach (Services.Document doc in main_window.document_view.docs) {
            var view = doc.source_view;
            var gvls_provider = view.get_data<GVlsui.CompletionProvider> ("gvls-provider");
            if (gvls_provider == null) {
                return;
            }

            try {
                view.get_completion ().remove_provider (gvls_provider);
            } catch (GLib.Error e) {
                warning (_("Error deactivating GVls Plugin: %s"), e.message);
            }
        }

        var gvls_client = plugins.get_data<GVls.Client> ("gvls-client");
        if (gvls_client != null) {
            gvls_client.server_shutdown.begin ();
        }

        if (timed_id != 0) {
            Source.remove (timed_id);
        }
    }

    public void update_state () {}

    private bool push_document_changes () {
        if (lsp_sync_in_progress) {
            return true;
        }

        var doc = main_window.get_current_document ();
        if (doc == null) {
            return Source.CONTINUE;
        }

        var view = doc.source_view;
        var file = doc.file;
        var gvls_changes = view.get_data<GVls.Container> ("gvls-changes");
        var gvls_manager = view.get_data<GVlsp.ProjectManager> ("gvls-manager");
        if (gvls_changes == null || gvls_manager == null) {
            return true;
        }

        if (gvls_changes.get_n_items () != 0) {
            var gvls_client = gvls_manager.client;
            GVls.Container current_changes = gvls_changes;
            gvls_changes = new GVls.ContainerHashList.for_type (typeof (GVls.TextDocumentContentChangeEventInfo));
            view.set_data<GVls.Container> ("gvls-changes", gvls_changes);
            lsp_sync_in_progress = true;
            gvls_client.document_change.begin (file.get_uri (), current_changes, (obj, res) => {
                try {
                    gvls_client.document_change.end (res);
                    lsp_sync_in_progress = false;
                } catch (GLib.Error e) {
                    warning ("Error while pushing changes to the server: %s", e.message);
                }
            });
        }

        return Source.CONTINUE;
    }
}

[ModuleInit]
public void peas_register_types (TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type (typeof (Peas.Activatable),
                                       typeof (Scratch.Plugins.GVlsCompletion));
}
