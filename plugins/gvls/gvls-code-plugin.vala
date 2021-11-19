/* 
 * Copyright 2022 elementary, Inc. (https://elementary.io)
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
 * Authors: Daniel Espinosa <esodan@gmail.com>, 
            Jeremy Wootten <jeremywootten@gmail.com>
 */

public class Scratch.Plugins.GVlsCompletion : Peas.ExtensionBase, Peas.Activatable {
    private MainWindow main_window;

    public Object object { owned get; construct; }
    Scratch.Services.Interface plugins;

    public void activate () {
    warning ("GVLS activate");
        plugins = (Scratch.Services.Interface) object;
        this.main_window = plugins.manager.window;

        plugins.hook_document.connect (on_hook_document);
    }

    private void on_hook_document (Scratch.Services.Document doc) {
warning ("on hook document");
        if (doc.source_view.project == null) {
warning ("no project");
            return;
        }

        var gvls_manager = doc.source_view.project.get_data<GVlsui.ProjectManager> ("gvls-manager");
        if (gvls_manager == null) {
        warning ("get gvls manager");
            GLib.File f = doc.source_view.project.file.file;
            gvls_manager = new GVlsui.ProjectManager.for_meson (f);
            doc.source_view.project.set_data<GVlsui.ProjectManager> ("gvls-manager", gvls_manager);
            gvls_manager.manager.initialize_stdio.begin ((obj, res)=>{
                try {
                    gvls_manager.manager.initialize_stdio.end (res);
                    warning ("gvls-plugin: Started GVls server");

                    main_window.destroy.connect (()=>{
                        gvls_manager.manager.client.server_exit.begin ();
                    });

            warning ("connecting completion provider ");
                    gvls_manager.set_completion_provider (doc.source_view, doc.file);
                    gvls_manager.open_document (doc.source_view);
                } catch (GLib.Error e) {
                    warning ("Error Opening File: %s", e.message);
                }
            });
        }
    }

    public void deactivate () {
    warning ("GVLS deactivate");
        if (main_window == null) {
            message ("No MainWindow was set");
            return;
        }

        foreach (Services.Document doc in main_window.document_view.docs) {
            var p = doc.source_view.project;
            var gvls_manager = p.get_data<GVlsui.ProjectManager> ("gvls-manager");

            if (gvls_manager == null) {
                continue;
            }

            gvls_manager.manager.client.server_exit.begin (()=>{
                p.set_data<GVlsui.ProjectManager?> ("gvls-manager", null);
            });
        }
    }

    public void update_state () {}
}

[ModuleInit]
public void peas_register_types (TypeModule module) {
    var objmodule = module as Peas.ObjectModule;
    objmodule.register_extension_type (typeof (Peas.Activatable),
                                       typeof (Scratch.Plugins.GVlsCompletion));
}
