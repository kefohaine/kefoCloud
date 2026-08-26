package net.fxmq.whitelistmsg;

import net.kyori.adventure.text.Component;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.core.LogEvent;
import org.apache.logging.log4j.core.LoggerContext;
import org.apache.logging.log4j.core.filter.AbstractFilter;
import org.bukkit.Bukkit;
import org.bukkit.entity.Player;
import org.bukkit.event.EventHandler;
import org.bukkit.event.EventPriority;
import org.bukkit.event.Listener;
import org.bukkit.event.player.PlayerLoginEvent;
import org.bukkit.plugin.java.JavaPlugin;

/**
 * Collapse the whitelist-rejection log spam (Paper "Disconnecting ...", Paper
 * "... lost connection ...", Geyser "has disconnected from the Java server ...",
 * Floodgate "logged in as ... disconnected") into ONE custom line, and send the
 * client a kick message that includes the username:
 *
 *   log:    /<ip>:<port> lost connection: You (<name>) are not whitelisted on this server!
 *   client: You (<name>) are not whitelisted on this server!
 */
public final class WhitelistMsg extends JavaPlugin implements Listener {

    @Override
    public void onEnable() {
        getServer().getPluginManager().registerEvents(this, this);
        try {
            LoggerContext ctx = (LoggerContext) LogManager.getContext(false);
            ctx.getConfiguration().getRootLogger().addFilter(new NoiseFilter());
            ctx.updateLoggers();
            getLogger().info("installed whitelist-kick log filter");
        } catch (Throwable t) {
            getLogger().warning("could not install log filter: " + t);
        }
    }

    @EventHandler(priority = EventPriority.MONITOR)
    public void onLogin(PlayerLoginEvent event) {
        if (event.getResult() != PlayerLoginEvent.Result.KICK_WHITELIST) {
            return;
        }
        Player player = event.getPlayer();
        String name = player.getName();
        String addr = event.getAddress() == null ? "?" :
                "/" + event.getAddress().getHostAddress() + ":0";
        String message = "You (" + name + ") are not whitelisted on this server!";
        event.kickMessage(Component.text(message));
        Bukkit.getLogger().info(addr + " lost connection: " + message);
    }

    /** Suppress the four default whitelist-kick log lines. */
    private static final class NoiseFilter extends AbstractFilter {

        @Override
        public Result filter(LogEvent event) {
            String msg = event.getMessage() == null ? null : event.getMessage().getFormattedMessage();
            return isNoise(msg) ? Result.DENY : Result.NEUTRAL;
        }

        private static boolean isNoise(String msg) {
            if (msg == null) {
                return false;
            }
            String m = msg.toLowerCase();
            if (m.contains("you are not whitelisted on this server")) {
                return true;
            }
            if (m.startsWith("[geyser-spigot]") && m.contains("has disconnected from the java server because of")) {
                return true;
            }
            if (m.startsWith("[floodgate]") && m.contains("logged in as") && m.contains("disconnected")) {
                return true;
            }
            return false;
        }
    }
}
